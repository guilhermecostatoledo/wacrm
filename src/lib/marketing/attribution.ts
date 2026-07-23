export type AttributionModel = "first_touch" | "last_touch";

export interface MarketingTouchpoint {
  id: string;
  campaignId: string;
  occurredAt: string;
  eventType: string;
}

export interface UtmParameters {
  source?: string;
  medium?: string;
  campaign?: string;
  term?: string;
  content?: string;
}

function normalize(value: string | null): string | undefined {
  const text = value?.trim();
  return text ? text.slice(0, 200) : undefined;
}

export function parseUtmParameters(input: string | URL): UtmParameters {
  const url = input instanceof URL ? input : new URL(input);
  return {
    source: normalize(url.searchParams.get("utm_source")),
    medium: normalize(url.searchParams.get("utm_medium")),
    campaign: normalize(url.searchParams.get("utm_campaign")),
    term: normalize(url.searchParams.get("utm_term")),
    content: normalize(url.searchParams.get("utm_content")),
  };
}

export function chooseAttributedTouchpoint(
  touchpoints: readonly MarketingTouchpoint[],
  model: AttributionModel,
): MarketingTouchpoint | null {
  const valid = touchpoints
    .filter((touchpoint) => Number.isFinite(new Date(touchpoint.occurredAt).getTime()))
    .sort((a, b) => {
      const time = new Date(a.occurredAt).getTime() - new Date(b.occurredAt).getTime();
      return time !== 0 ? time : a.id.localeCompare(b.id);
    });

  if (valid.length === 0) return null;
  return model === "first_touch" ? valid[0] : valid[valid.length - 1];
}

export function isContactableConsent(status: string | null | undefined): boolean {
  return status === "opted_in" || status === "transactional_only";
}
