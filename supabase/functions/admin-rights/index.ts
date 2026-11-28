import { createClient } from "https://esm.sh/@supabase/supabase-js@2.119.0";
import { getSupabasePublishableKey, getSupabaseSecretKey, createSupabaseFetch } from "../_shared/api-keys.ts";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS", "Content-Type": "application/json" };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: cors });
const uuid = (v: unknown): v is string => typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v);

let diagnosticStage = "request_start";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  try {
    const url = Deno.env.get("SUPABASE_URL");
    const publishable = getSupabasePublishableKey();
    const secret = getSupabaseSecretKey();
    if (!url || !secret) return json({ error: "server_configuration_incomplete" }, 503);
    const header = req.headers.get("Authorization") || "";
    const token = header.startsWith("Bearer ") ? header.slice(7) : "";
    if (!token) return json({ error: "unauthorized" }, 401);

    const caller = createClient(url, publishable, {
      global: { fetch: createSupabaseFetch(publishable), headers: { Authorization: "Bearer " + token } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    diagnosticStage = "auth_validation";
    const { data: auth, error: authError } = await caller.auth.getUser(token);
    if (authError || !auth.user) return json({ error: "unauthorized" }, 401);
    diagnosticStage = "permission_check";
    const { data: isAdmin } = await caller.rpc("has_admin_access", { p_user_id: auth.user.id });
    const { data: isSuperAdmin } = await caller.rpc("is_super_admin", { p_user_id: auth.user.id });
    const { data: canAdjust } = await caller.rpc("admin_has_permission", {
      p_permission_key: "finance.wallet.adjust", p_scope_type: "global", p_scope_governorate: null,
    });
    if (isAdmin !== true && canAdjust !== true && isSuperAdmin !== true) return json({ error: "forbidden" }, 403);

    const admin = createClient(url, secret, {
      global: { fetch: createSupabaseFetch(secret) },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const body = await req.json().catch(() => null);
    if (!body || typeof body.action !== "string") return json({ error: "invalid_request" }, 400);

    if (body.action === "search_users") {
      const rawQuery = typeof body.query === "string" ? body.query.trim().slice(0, 100) : "";
      if (rawQuery.length < 2) return json({ error: "query_too_short" }, 400);

      // Search names/emails independently from phone variants. This avoids
      // PostgREST OR-filter parsing issues and supports Iraqi phone formats.
      const normalizedDigits = rawQuery.replace(/[٠-٩۰-۹]/g, (digit) => {
        const code = digit.charCodeAt(0);
        return String(code >= 0x06f0 ? code - 0x06f0 : code - 0x0660);
      }).replace(/\D/g, "");
      const phoneCandidates = new Set<string>();
      if (normalizedDigits) {
        phoneCandidates.add(normalizedDigits);
        if (normalizedDigits.startsWith("00")) phoneCandidates.add(normalizedDigits.slice(2));
        if (normalizedDigits.startsWith("964")) {
          phoneCandidates.add("+" + normalizedDigits);
          phoneCandidates.add("0" + normalizedDigits.slice(3));
          phoneCandidates.add(normalizedDigits.slice(3));
        } else if (normalizedDigits.startsWith("0")) {
          phoneCandidates.add("964" + normalizedDigits.slice(1));
          phoneCandidates.add("+964" + normalizedDigits.slice(1));
          phoneCandidates.add(normalizedDigits.slice(1));
        } else if (normalizedDigits.startsWith("7")) {
          phoneCandidates.add("0" + normalizedDigits);
          phoneCandidates.add("964" + normalizedDigits);
          phoneCandidates.add("+964" + normalizedDigits);
        }
      }

      const safeText = rawQuery.replace(/[,%()]/g, " ").replace(/[*]/g, "").trim();
      const [nameResult, emailResult, phoneResult] = await Promise.all([
        admin.from("profiles").select("id,full_name,phone,email,governorate_key,created_at")
          .ilike("full_name", "%" + safeText + "%").order("created_at", { ascending: false }).limit(40),
        admin.from("profiles").select("id,full_name,phone,email,governorate_key,created_at")
          .ilike("email", "%" + safeText + "%").order("created_at", { ascending: false }).limit(40),
        phoneCandidates.size
          ? admin.from("profiles").select("id,full_name,phone,email,governorate_key,created_at")
              .or([...phoneCandidates].map((phone) => "phone.ilike.%" + phone.replace(/[,%()]/g, "") + "%").join(","))
              .order("created_at", { ascending: false }).limit(40)
          : Promise.resolve({ data: [], error: null }),
      ]);
      const failedSearch = [nameResult, emailResult, phoneResult].find((result: any) => result.error);
      if (failedSearch?.error) {
        console.error("[admin-rights] user search failed", failedSearch.error.message);
        return json({ error: "user_search_failed" }, 500);
      }
      const profileMap = new Map<string, any>();
      for (const profile of [...(nameResult.data ?? []), ...(emailResult.data ?? []), ...(phoneResult.data ?? [])]) {
        profileMap.set(profile.id, profile);
      }
      const profiles = [...profileMap.values()]
        .sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)))
        .slice(0, 40);
      const ids = profiles.map((profile: any) => profile.id);
      const [rolesResult, partnersResult, walletsResult] = await Promise.all([
        ids.length ? admin.from("user_roles").select("user_id,role").in("user_id", ids) : Promise.resolve({ data: [], error: null }),
        ids.length ? admin.from("partner_business_profiles").select("user_id,partner_type,business_vertical,business_name").in("user_id", ids) : Promise.resolve({ data: [], error: null }),
        ids.length ? admin.from("account_wallets").select("user_id,balance_iqd").in("user_id", ids) : Promise.resolve({ data: [], error: null }),
      ]);
      const enrichmentError = [rolesResult, partnersResult, walletsResult].find((result: any) => result.error);
      if (enrichmentError?.error) {
        console.error("[admin-rights] user search enrichment failed", enrichmentError.error.message);
        return json({ error: "user_search_details_failed" }, 500);
      }
      const rolesMap = new Map<string, string[]>();
      for (const role of rolesResult.data ?? []) rolesMap.set(role.user_id, [...(rolesMap.get(role.user_id) ?? []), String(role.role)]);
      const partnerMap = new Map((partnersResult.data ?? []).map((partner: any) => [partner.user_id, partner]));
      const walletMap = new Map((walletsResult.data ?? []).map((wallet: any) => [wallet.user_id, Number(wallet.balance_iqd)]));
      return json({ users: profiles.map((profile: any) => ({
        ...profile, roles: rolesMap.get(profile.id) ?? [], partner: partnerMap.get(profile.id) ?? null,
        balance_iqd: walletMap.get(profile.id) ?? 0,
      })) });
    }

    if (body.action === "wallet_adjust") {
      if (!uuid(body.user_id) || !Number.isSafeInteger(body.amount_iqd) || body.amount_iqd <= 0 ||
          !["credit","debit"].includes(body.type) || typeof body.note !== "string" ||
          body.note.trim().length < 2 || body.note.length > 500 ||
          typeof body.idempotency_key !== "string" || body.idempotency_key.length < 8 || body.idempotency_key.length > 200) {
        return json({ error: "invalid_wallet_adjustment" }, 400);
      }
      const { data, error } = await caller.rpc("admin_adjust_account_wallet", {
        p_user_id: body.user_id, p_amount_iqd: body.amount_iqd, p_type: body.type,
        p_note: body.note.trim(), p_idempotency_key: body.idempotency_key,
      });
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true, result: data });
    }

    if (body.action === "save_override") {
      if (isSuperAdmin !== true) return json({ error: "super_admin_required" }, 403);
      if (!uuid(body.user_id) || typeof body.charge_percent !== "number" ||
          !Number.isFinite(body.charge_percent) || body.charge_percent < 0 || body.charge_percent > 100 ||
          typeof body.reason !== "string" || body.reason.trim().length < 2 || body.reason.length > 500 ||
          (body.starts_at != null && (typeof body.starts_at !== "string" || !Number.isFinite(Date.parse(body.starts_at)))) ||
          (body.ends_at != null && (typeof body.ends_at !== "string" || !Number.isFinite(Date.parse(body.ends_at))))) {
        return json({ error: "invalid_user_override" }, 400);
      }
      const { data, error } = await caller.rpc("admin_set_user_fee_override", {
        p_user_id: body.user_id, p_charge_percent: body.charge_percent,
        p_starts_at: body.starts_at ?? null, p_ends_at: body.ends_at ?? null, p_reason: body.reason.trim(),
      });
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true, override_id: data });
    }

    if (body.action === "revoke_override") {
      if (isSuperAdmin !== true || !uuid(body.override_id)) return json({ error: "super_admin_required_or_invalid_id" }, 403);
      const { data, error } = await caller.rpc("admin_revoke_user_fee_override", { p_override_id: body.override_id });
      if (error) return json({ error: error.message }, 400);
      return json({ ok: data === true });
    }

    if (body.action === "list") {
      diagnosticStage = "list_query_batch";
      if (isSuperAdmin !== true) return json({ error: "super_admin_required" }, 403);
      const [policies, overrides, revenue, collections, collectionReversals] = await Promise.all([
        admin.from("mamnoon_commission_policies").select("*").order("created_at", { ascending: false }).limit(100),
        admin.from("mamnoon_user_fee_overrides").select("*").is("revoked_at", null).order("created_at", { ascending: false }).limit(200),
        admin.from("mamnoon_revenue_ledger").select("*").order("created_at", { ascending: false }).limit(200),
        admin.from("mamnoon_revenue_collections").select("id,revenue_ledger_id,payment_id,amount_iqd,provider_reference,created_at").order("created_at", { ascending: false }).limit(300),
        admin.from("mamnoon_revenue_collection_reversals").select("revenue_collection_id,amount_iqd,reason,created_at").limit(500),
      ]);
      if (policies.error || overrides.error || revenue.error || collections.error || collectionReversals.error) {
        console.error("admin-rights list query failed", { policies: policies.error?.message ?? null, overrides: overrides.error?.message ?? null, revenue: revenue.error?.message ?? null, collections: collections.error?.message ?? null, reversals: collectionReversals.error?.message ?? null });
        return json({ error: "rights_data_load_failed" }, 500);
      }
      const ids = [...new Set((overrides.data ?? []).map((r:any)=>r.user_id).concat((revenue.data ?? []).map((r:any)=>r.user_id)))];
      diagnosticStage = "list_profiles";
      const { data: profiles } = ids.length ? await admin.from("profiles").select("id,full_name,phone").in("id",ids) : { data: [] };
      const byId = new Map((profiles ?? []).map((p:any)=>[p.id,p]));
      const collectionPaymentIds = [...new Set((collections.data ?? []).map((row:any)=>row.payment_id).filter(Boolean))];
      diagnosticStage = "list_collection_payments";
      const { data: collectionPayments, error: collectionPaymentsError } = collectionPaymentIds.length
        ? await admin.from("payment_transactions").select("id,purpose,provider,status").in("id",collectionPaymentIds)
        : { data: [], error: null };
      if (collectionPaymentsError) { console.error("admin-rights payment lookup failed", collectionPaymentsError.message); return json({ error: "rights_collection_payment_load_failed" }, 500); }
      const collectionPaymentById = new Map((collectionPayments ?? []).map((row:any)=>[row.id,row]));
      const requestIds = [...new Set((revenue.data ?? []).map((row:any)=>row.request_id).filter(Boolean))];
      diagnosticStage = "list_service_requests";
      const { data: requests, error: requestsError } = requestIds.length
        ? await admin.from("service_requests").select("id,request_code").in("id",requestIds)
        : { data: [], error: null };
      if (requestsError) { console.error("admin-rights request lookup failed", requestsError.message); return json({ error: "rights_request_codes_load_failed" }, 500); }
      const requestCodeById = new Map((requests ?? []).map((row:any)=>[row.id,row.request_code]));
      diagnosticStage = "list_revenue_summary";
      const { data: summary, error: summaryError } = await caller.rpc("admin_get_revenue_summary");
      if (summaryError) { console.error("admin-rights revenue summary failed", summaryError.message); return json({ error: "revenue_summary_load_failed" }, 500); }
      return json({
        summary: summary ?? {},
        policies: policies.data ?? [],
        overrides: (overrides.data ?? []).map((r:any)=>({...r,profile:byId.get(r.user_id) ?? null})),
        revenue: (revenue.data ?? []).map((r:any)=>({...r,profile:byId.get(r.user_id) ?? null,request_code:requestCodeById.get(r.request_id) ?? null})),
        collections: (collections.data ?? []).map((row:any) => {
          const reversal = (collectionReversals.data ?? []).find((item:any) => item.revenue_collection_id === row.id);
          const ledger = (revenue.data ?? []).find((item:any) => item.id === row.revenue_ledger_id);
          return {
            ...row,
            reversed_amount_iqd: reversal?.amount_iqd ?? 0,
            net_amount_iqd: Math.max(0, Number(row.amount_iqd ?? 0) - Number(reversal?.amount_iqd ?? 0)),
            reversal_reason: reversal?.reason ?? null,
            reversed_at: reversal?.created_at ?? null,
            refund_review_pending: ledger?.metadata?.refund_review_pending === true,
            payment_purpose: collectionPaymentById.get(row.payment_id)?.purpose ?? null,
            payment_provider: collectionPaymentById.get(row.payment_id)?.provider ?? null,
          };
        }),
      });
    }

    if (body.action === "save_policy") {
      if (isSuperAdmin !== true) return json({ error: "super_admin_required" }, 403);
      const { data, error } = await caller.rpc("admin_save_commission_policy", {
        p_scope_type: body.scope_type, p_scope_key: body.scope_key ?? null,
        p_commission_rate_percent: body.commission_rate_percent,
        p_commission_charge_percent: body.commission_charge_percent,
        p_collection_event: body.collection_event,
        p_free_trial_enabled: body.free_trial_enabled === true,
        p_free_trial_days: body.free_trial_days,
        p_new_users_only: body.new_users_only === true,
        p_is_enabled: body.is_enabled === true,
        p_starts_at: body.starts_at ?? null, p_ends_at: body.ends_at ?? null,
      });
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true, policy_id: data });
    }

    return json({ error: "unknown_action" }, 400);
  } catch (error) {
    console.error("admin-rights unhandled failure", { stage: diagnosticStage, message: String(error).slice(0, 300) });
    return json({ error: "internal_error", stage: diagnosticStage }, 500);
  }
});
