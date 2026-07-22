'use client';

import { useCallback, useEffect, useState } from 'react';

import { useAuth } from '@/hooks/use-auth';
import { createClient } from '@/lib/supabase/client';

export function useCrmNotifications() {
  const supabase = createClient();
  const { user, accountId } = useAuth();
  const [count, setCount] = useState(0);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    if (!user?.id || !accountId) {
      setCount(0);
      setLoading(false);
      return;
    }

    const { count: exactCount, error } = await supabase
      .from('crm_notifications')
      .select('id', { count: 'exact', head: true })
      .eq('account_id', accountId)
      .eq('user_id', user.id)
      .is('dismissed_at', null);

    if (!error) setCount(exactCount ?? 0);
    setLoading(false);
  }, [accountId, supabase, user?.id]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  useEffect(() => {
    if (!accountId || !user?.id) return;

    const channel = supabase
      .channel(`crm-notifications:${accountId}:${user.id}`)
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'crm_notifications',
          filter: `account_id=eq.${accountId}`,
        },
        () => void refresh(),
      )
      .subscribe();

    return () => {
      void supabase.removeChannel(channel);
    };
  }, [accountId, refresh, supabase, user?.id]);

  return { count, loading, refresh };
}
