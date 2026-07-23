import { NextResponse } from 'next/server';
import { createClient } from '@/lib/supabase/server';

export async function GET() {
  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  const { data: profile } = await supabase
    .from('profiles')
    .select('account_id')
    .eq('user_id', user.id)
    .maybeSingle();
  const accountId = profile?.account_id as string | undefined;
  if (!accountId) {
    return NextResponse.json({ error: 'Profile is not linked to an account' }, { status: 403 });
  }

  const { data: canAudit } = await supabase.rpc('has_account_capability', {
    target_account_id: accountId,
    target_capability: 'audit.read',
  });
  if (!canAudit) {
    return NextResponse.json({ error: 'Forbidden' }, { status: 403 });
  }

  const [config, pending, deadLetters, latestReceipt, latestAttempt] = await Promise.all([
    supabase
      .from('whatsapp_config')
      .select(
        'provider,status,phone_number_id,provider_instance_id,last_health_at,last_health_ok,last_health_details,updated_at',
      )
      .eq('account_id', accountId)
      .maybeSingle(),
    supabase
      .from('whatsapp_webhook_receipts')
      .select('id', { count: 'exact', head: true })
      .eq('account_id', accountId)
      .in('status', ['pending', 'processing', 'failed']),
    supabase
      .from('integration_dead_letters')
      .select('id', { count: 'exact', head: true })
      .eq('account_id', accountId)
      .eq('integration_type', 'whatsapp')
      .is('resolved_at', null),
    supabase
      .from('whatsapp_webhook_receipts')
      .select('provider,event_type,status,received_at,processed_at,error_code')
      .eq('account_id', accountId)
      .order('received_at', { ascending: false })
      .limit(1)
      .maybeSingle(),
    supabase
      .from('whatsapp_delivery_attempts')
      .select('provider,status,attempt_number,started_at,finished_at,error_code')
      .eq('account_id', accountId)
      .order('started_at', { ascending: false })
      .limit(1)
      .maybeSingle(),
  ]);

  const queryError =
    config.error || pending.error || deadLetters.error || latestReceipt.error || latestAttempt.error;
  if (queryError) {
    console.error('[whatsapp/health] query failed:', queryError);
    return NextResponse.json({ error: 'Failed to load integration health' }, { status: 500 });
  }

  const pendingCount = pending.count ?? 0;
  const deadLetterCount = deadLetters.count ?? 0;
  const connected = config.data?.status === 'connected';
  const degraded = pendingCount > 0 || deadLetterCount > 0 || config.data?.last_health_ok === false;

  return NextResponse.json({
    ok: connected && !degraded,
    state: !connected ? 'disconnected' : degraded ? 'degraded' : 'healthy',
    integration: config.data
      ? {
          provider: config.data.provider,
          status: config.data.status,
          phone_number_id: config.data.phone_number_id,
          provider_instance_id: config.data.provider_instance_id,
          last_health_at: config.data.last_health_at,
          last_health_ok: config.data.last_health_ok,
          last_health_details: config.data.last_health_details,
          updated_at: config.data.updated_at,
        }
      : null,
    queue: {
      pending: pendingCount,
      open_dead_letters: deadLetterCount,
    },
    latest_receipt: latestReceipt.data,
    latest_delivery_attempt: latestAttempt.data,
    checked_at: new Date().toISOString(),
  });
}
