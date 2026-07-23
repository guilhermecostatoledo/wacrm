import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";

let mockUser: { id: string } | null = null;
let refreshedCookies: Array<{
  name: string;
  value: string;
  options: Record<string, unknown>;
}> = [];

vi.mock("@supabase/ssr", () => ({
  createServerClient: (
    _url: string,
    _key: string,
    opts: {
      cookies: { setAll: (c: typeof refreshedCookies) => void };
    },
  ) => ({
    auth: {
      getUser: async () => {
        if (refreshedCookies.length) opts.cookies.setAll(refreshedCookies);
        return { data: { user: mockUser } };
      },
    },
  }),
}));

const { middleware } = await import("./middleware");

beforeEach(() => {
  process.env.NEXT_PUBLIC_SUPABASE_URL = "https://test.supabase.co";
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY = "anon-key";
  mockUser = null;
  refreshedCookies = [];
});

afterEach(() => vi.clearAllMocks());

const ROTATED = {
  name: "sb-test-auth-token",
  value: "rotated-refresh-token",
  options: { path: "/", httpOnly: true },
};

const PROTECTED_PATHS = [
  "/dashboard",
  "/inbox",
  "/contacts",
  "/leads",
  "/tasks",
  "/pipelines",
  "/campaigns",
  "/reports",
  "/audit",
  "/broadcasts",
  "/automations",
  "/flows",
  "/notifications",
  "/agents",
  "/settings",
] as const;

describe("middleware — protected feature routes", () => {
  it.each(PROTECTED_PATHS)(
    "redirects an unauthenticated request for %s to /login",
    async (path) => {
      const res = await middleware(new NextRequest(`https://app.test${path}`));
      expect(res.status).toBe(307);
      expect(res.headers.get("location")).toContain("/login");
    },
  );

  it.each(PROTECTED_PATHS)(
    "allows an authenticated request for %s",
    async (path) => {
      mockUser = { id: "user-1" };
      const res = await middleware(new NextRequest(`https://app.test${path}`));
      expect(res.headers.get("location")).toBeNull();
    },
  );

  it("keeps the public invitation redemption page accessible", async () => {
    const res = await middleware(new NextRequest("https://app.test/join/invite-token"));
    expect(res.headers.get("location")).toBeNull();
  });
});

describe("middleware — refreshed auth cookies survive redirects", () => {
  it("carries the rotated token when redirecting a signed-in user off /login", async () => {
    mockUser = { id: "user-1" };
    refreshedCookies = [ROTATED];

    const res = await middleware(new NextRequest("https://app.test/login"));
    expect(res.status).toBe(307);
    expect(res.headers.get("location")).toContain("/dashboard");
    expect(res.cookies.get(ROTATED.name)?.value).toBe(ROTATED.value);
  });

  it("carries the rotated token when redirecting an unauth user to /login", async () => {
    refreshedCookies = [{ ...ROTATED, value: "cleared" }];
    const res = await middleware(new NextRequest("https://app.test/dashboard"));
    expect(res.status).toBe(307);
    expect(res.headers.get("location")).toContain("/login");
    expect(res.cookies.get(ROTATED.name)?.value).toBe("cleared");
  });

  it("redirects a signed-in user with an invite token to /join/<token>", async () => {
    mockUser = { id: "user-1" };
    refreshedCookies = [ROTATED];
    const res = await middleware(new NextRequest("https://app.test/login?invite=abc123"));
    expect(res.headers.get("location")).toContain("/join/abc123");
    expect(res.cookies.get(ROTATED.name)?.value).toBe(ROTATED.value);
  });

  it("passes through for a signed-in user on a protected page", async () => {
    mockUser = { id: "user-1" };
    refreshedCookies = [ROTATED];
    const res = await middleware(new NextRequest("https://app.test/leads"));
    expect(res.headers.get("location")).toBeNull();
    expect(res.cookies.get(ROTATED.name)?.value).toBe(ROTATED.value);
  });
});
