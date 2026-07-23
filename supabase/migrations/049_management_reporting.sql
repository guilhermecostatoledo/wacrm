-- ============================================================
-- 049_management_reporting.sql
--
-- Server-side management report. Heavy aggregations stay in PostgreSQL and
-- return one bounded JSON document instead of downloading entire tables to
-- the browser.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.crm_management_report(
  p_account_id UUID,
  p_from TIMESTAMPTZ,
  p_to TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN
    RAISE EXCEPTION 'A valid reporting period is required'
      USING ERRCODE = 'check_violation';
  END IF;
  IF p_to - p_from > INTERVAL '370 days' THEN
    RAISE EXCEPTION 'Reporting period cannot exceed 370 days'
      USING ERRCODE = 'check_violation';
  END IF;
  IF NOT public.has_account_capability(p_account_id, 'report.view') THEN
    RAISE EXCEPTION 'Missing report.view capability'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  WITH
  lead_metrics AS (
    SELECT
      count(*) FILTER (WHERE l.created_at >= p_from AND l.created_at < p_to) AS captured,
      count(*) FILTER (WHERE l.first_contacted_at >= p_from AND l.first_contacted_at < p_to) AS contacted,
      count(*) FILTER (WHERE l.qualified_at >= p_from AND l.qualified_at < p_to) AS qualified,
      count(*) FILTER (WHERE l.converted_at >= p_from AND l.converted_at < p_to) AS converted,
      count(*) FILTER (WHERE l.disqualified_at >= p_from AND l.disqualified_at < p_to) AS disqualified,
      count(*) FILTER (
        WHERE l.created_at >= p_from AND l.created_at < p_to
          AND l.first_response_due_at IS NOT NULL
          AND (
            l.first_contacted_at > l.first_response_due_at
            OR (l.first_contacted_at IS NULL AND l.first_response_due_at < LEAST(p_to, NOW()))
          )
      ) AS sla_breaches,
      avg(EXTRACT(EPOCH FROM (l.first_contacted_at - l.created_at)) / 60.0)
        FILTER (
          WHERE l.created_at >= p_from AND l.created_at < p_to
            AND l.first_contacted_at IS NOT NULL
            AND l.first_contacted_at >= l.created_at
        ) AS avg_first_response_minutes
    FROM public.leads l
    WHERE l.account_id = p_account_id
      AND l.archived_at IS NULL
  ),
  task_metrics AS (
    SELECT
      count(*) FILTER (WHERE t.status IN ('open', 'in_progress') AND t.archived_at IS NULL) AS active,
      count(*) FILTER (
        WHERE t.status IN ('open', 'in_progress')
          AND t.archived_at IS NULL
          AND t.due_at < NOW()
      ) AS overdue,
      count(*) FILTER (
        WHERE t.status = 'completed'
          AND t.completed_at >= p_from AND t.completed_at < p_to
      ) AS completed,
      count(*) FILTER (
        WHERE t.status = 'cancelled'
          AND t.cancelled_at >= p_from AND t.cancelled_at < p_to
      ) AS cancelled,
      avg(EXTRACT(EPOCH FROM (t.completed_at - t.created_at)) / 3600.0)
        FILTER (
          WHERE t.status = 'completed'
            AND t.completed_at >= p_from AND t.completed_at < p_to
            AND t.completed_at >= t.created_at
        ) AS avg_completion_hours
    FROM public.tasks t
    WHERE t.account_id = p_account_id
  ),
  opportunity_metrics AS (
    SELECT
      count(*) FILTER (WHERE d.status = 'open' AND d.archived_at IS NULL) AS open_count,
      COALESCE(sum(d.value) FILTER (WHERE d.status = 'open' AND d.archived_at IS NULL), 0) AS open_value,
      COALESCE(sum(d.value * d.probability / 100.0)
        FILTER (WHERE d.status = 'open' AND d.archived_at IS NULL), 0) AS weighted_value,
      count(*) FILTER (WHERE d.status = 'won' AND d.won_at >= p_from AND d.won_at < p_to) AS won_count,
      COALESCE(sum(d.value) FILTER (
        WHERE d.status = 'won' AND d.won_at >= p_from AND d.won_at < p_to
      ), 0) AS won_value,
      count(*) FILTER (WHERE d.status = 'lost' AND d.lost_at >= p_from AND d.lost_at < p_to) AS lost_count,
      COALESCE(sum(d.value) FILTER (
        WHERE d.status = 'lost' AND d.lost_at >= p_from AND d.lost_at < p_to
      ), 0) AS lost_value
    FROM public.deals d
    WHERE d.account_id = p_account_id
  ),
  marketing_metrics AS (
    SELECT
      COALESCE((
        SELECT sum(c.budget)
        FROM public.marketing_campaigns c
        WHERE c.account_id = p_account_id
          AND c.archived_at IS NULL
          AND COALESCE(c.starts_at, c.created_at) < p_to
          AND COALESCE(c.ends_at, p_to) >= p_from
      ), 0) AS investment,
      COALESCE((
        SELECT sum(a.attributed_revenue)
        FROM public.opportunity_attributions a
        JOIN public.deals d ON d.id = a.opportunity_id
        WHERE a.account_id = p_account_id
          AND a.model = 'last_touch'
          AND d.won_at >= p_from AND d.won_at < p_to
      ), 0) AS attributed_revenue,
      COALESCE((
        SELECT count(*)
        FROM public.marketing_touchpoints t
        WHERE t.account_id = p_account_id
          AND t.occurred_at >= p_from AND t.occurred_at < p_to
      ), 0) AS touchpoints,
      COALESCE((
        SELECT count(*)
        FROM public.marketing_touchpoints t
        WHERE t.account_id = p_account_id
          AND t.event_type = 'reply'
          AND t.occurred_at >= p_from AND t.occurred_at < p_to
      ), 0) AS replies
  ),
  whatsapp_metrics AS (
    SELECT
      count(*) FILTER (
        WHERE r.status = 'succeeded' AND r.received_at >= p_from AND r.received_at < p_to
      ) AS processed,
      count(*) FILTER (
        WHERE r.status IN ('failed', 'dead_letter')
          AND r.received_at >= p_from AND r.received_at < p_to
      ) AS failed,
      count(*) FILTER (WHERE r.status = 'dead_letter') AS dead_letter_receipts,
      COALESCE((
        SELECT count(*) FROM public.integration_dead_letters dl
        WHERE dl.account_id = p_account_id
          AND dl.integration_type = 'whatsapp'
          AND dl.resolved_at IS NULL
      ), 0) AS open_dead_letters
    FROM public.whatsapp_webhook_receipts r
    WHERE r.account_id = p_account_id
  ),
  daily_series AS (
    SELECT jsonb_agg(
      jsonb_build_object(
        'day', day::DATE,
        'leads', (
          SELECT count(*) FROM public.leads l
          WHERE l.account_id = p_account_id
            AND l.created_at >= day AND l.created_at < day + INTERVAL '1 day'
        ),
        'qualified', (
          SELECT count(*) FROM public.leads l
          WHERE l.account_id = p_account_id
            AND l.qualified_at >= day AND l.qualified_at < day + INTERVAL '1 day'
        ),
        'won_revenue', COALESCE((
          SELECT sum(d.value) FROM public.deals d
          WHERE d.account_id = p_account_id
            AND d.status = 'won'
            AND d.won_at >= day AND d.won_at < day + INTERVAL '1 day'
        ), 0)
      ) ORDER BY day
    ) AS value
    FROM generate_series(
      date_trunc('day', p_from),
      date_trunc('day', p_to - INTERVAL '1 microsecond'),
      INTERVAL '1 day'
    ) AS day
  ),
  pipeline_breakdown AS (
    SELECT jsonb_agg(
      jsonb_build_object(
        'stage_id', s.id,
        'stage_name', s.name,
        'stage_kind', s.stage_kind,
        'opportunities', COALESCE(x.opportunity_count, 0),
        'value', COALESCE(x.total_value, 0),
        'weighted_value', COALESCE(x.weighted_value, 0)
      ) ORDER BY s.position
    ) AS value
    FROM public.pipeline_stages s
    JOIN public.pipelines p ON p.id = s.pipeline_id
    LEFT JOIN LATERAL (
      SELECT
        count(*) AS opportunity_count,
        sum(d.value) AS total_value,
        sum(d.value * d.probability / 100.0) AS weighted_value
      FROM public.deals d
      WHERE d.account_id = p_account_id
        AND d.stage_id = s.id
        AND d.status = 'open'
        AND d.archived_at IS NULL
    ) x ON true
    WHERE p.account_id = p_account_id
  ),
  owner_performance AS (
    SELECT jsonb_agg(
      jsonb_build_object(
        'user_id', p.user_id,
        'name', p.full_name,
        'leads_created', COALESCE(x.leads_created, 0),
        'qualified', COALESCE(x.qualified, 0),
        'tasks_completed', COALESCE(x.tasks_completed, 0),
        'won_count', COALESCE(x.won_count, 0),
        'won_revenue', COALESCE(x.won_revenue, 0)
      ) ORDER BY COALESCE(x.won_revenue, 0) DESC, p.full_name
    ) AS value
    FROM public.profiles p
    LEFT JOIN LATERAL (
      SELECT
        (SELECT count(*) FROM public.leads l
          WHERE l.account_id = p_account_id AND l.owner_id = p.user_id
            AND l.created_at >= p_from AND l.created_at < p_to) AS leads_created,
        (SELECT count(*) FROM public.leads l
          WHERE l.account_id = p_account_id AND l.owner_id = p.user_id
            AND l.qualified_at >= p_from AND l.qualified_at < p_to) AS qualified,
        (SELECT count(*) FROM public.tasks t
          WHERE t.account_id = p_account_id AND t.assigned_to = p.user_id
            AND t.completed_at >= p_from AND t.completed_at < p_to) AS tasks_completed,
        (SELECT count(*) FROM public.deals d
          WHERE d.account_id = p_account_id AND d.assigned_to = p.user_id
            AND d.status = 'won' AND d.won_at >= p_from AND d.won_at < p_to) AS won_count,
        (SELECT COALESCE(sum(d.value), 0) FROM public.deals d
          WHERE d.account_id = p_account_id AND d.assigned_to = p.user_id
            AND d.status = 'won' AND d.won_at >= p_from AND d.won_at < p_to) AS won_revenue
    ) x ON true
    WHERE p.account_id = p_account_id
  )
  SELECT jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'generated_at', NOW(),
    'leads', jsonb_build_object(
      'captured', lm.captured,
      'contacted', lm.contacted,
      'qualified', lm.qualified,
      'converted', lm.converted,
      'disqualified', lm.disqualified,
      'sla_breaches', lm.sla_breaches,
      'avg_first_response_minutes', round(COALESCE(lm.avg_first_response_minutes, 0)::NUMERIC, 2),
      'qualification_rate', round(
        CASE WHEN lm.captured = 0 THEN 0 ELSE lm.qualified::NUMERIC / lm.captured * 100 END,
        2
      ),
      'conversion_rate', round(
        CASE WHEN lm.captured = 0 THEN 0 ELSE lm.converted::NUMERIC / lm.captured * 100 END,
        2
      )
    ),
    'tasks', jsonb_build_object(
      'active', tm.active,
      'overdue', tm.overdue,
      'completed', tm.completed,
      'cancelled', tm.cancelled,
      'avg_completion_hours', round(COALESCE(tm.avg_completion_hours, 0)::NUMERIC, 2)
    ),
    'opportunities', jsonb_build_object(
      'open_count', om.open_count,
      'open_value', om.open_value,
      'weighted_value', round(om.weighted_value::NUMERIC, 2),
      'won_count', om.won_count,
      'won_value', om.won_value,
      'lost_count', om.lost_count,
      'lost_value', om.lost_value,
      'win_rate', round(
        CASE WHEN om.won_count + om.lost_count = 0 THEN 0
          ELSE om.won_count::NUMERIC / (om.won_count + om.lost_count) * 100 END,
        2
      )
    ),
    'marketing', jsonb_build_object(
      'investment', mm.investment,
      'attributed_revenue', mm.attributed_revenue,
      'roi_percent', round(
        CASE WHEN mm.investment = 0 THEN 0
          ELSE (mm.attributed_revenue - mm.investment) / mm.investment * 100 END,
        2
      ),
      'touchpoints', mm.touchpoints,
      'replies', mm.replies
    ),
    'whatsapp', jsonb_build_object(
      'processed', wm.processed,
      'failed', wm.failed,
      'dead_letter_receipts', wm.dead_letter_receipts,
      'open_dead_letters', wm.open_dead_letters
    ),
    'daily', COALESCE(ds.value, '[]'::jsonb),
    'pipeline', COALESCE(pb.value, '[]'::jsonb),
    'owners', COALESCE(op.value, '[]'::jsonb)
  ) INTO v_result
  FROM lead_metrics lm
  CROSS JOIN task_metrics tm
  CROSS JOIN opportunity_metrics om
  CROSS JOIN marketing_metrics mm
  CROSS JOIN whatsapp_metrics wm
  CROSS JOIN daily_series ds
  CROSS JOIN pipeline_breakdown pb
  CROSS JOIN owner_performance op;

  RETURN v_result;
END;
$$;

ALTER FUNCTION public.crm_management_report(UUID, TIMESTAMPTZ, TIMESTAMPTZ)
  OWNER TO postgres;
REVOKE ALL ON FUNCTION public.crm_management_report(UUID, TIMESTAMPTZ, TIMESTAMPTZ)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.crm_management_report(UUID, TIMESTAMPTZ, TIMESTAMPTZ)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.crm_management_report(UUID, TIMESTAMPTZ, TIMESTAMPTZ) IS
  'Bounded server-side management report for leads, tasks, opportunities, marketing and WhatsApp health.';

COMMIT;
