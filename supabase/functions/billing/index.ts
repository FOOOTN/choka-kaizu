// 会員の申し込み・支払い方法の変更・状態の読み直し（アプリから呼ぶ）
// Supabase の Edge Functions に「billing」という名前で置く（JWT の確認はオンのまま）
// 必要な Secrets：STRIPE_SECRET_KEY・STRIPE_PRICE_ID・APP_URL（例 https://foootn.github.io/choka-kaizu/）
import Stripe from "npm:stripe@17.7.0";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { httpClient: Stripe.createFetchHttpClient() });
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const APP_URL = Deno.env.get("APP_URL") || "https://foootn.github.io/choka-kaizu/";
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (d: unknown, status = 200) => new Response(JSON.stringify(d), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const TRIAL_MONTHS = 2;                       // 最初の無料期間（1＋1か月）
export const TSUNUKE_COUPON = "tsunuke";      // つ抜け会員の割引（100%・ずっと）

async function rpc(fn: string, args: Record<string, unknown>) {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
}
async function ensureCoupon() {
  try { await stripe.coupons.retrieve(TSUNUKE_COUPON); }
  catch { await stripe.coupons.create({ id: TSUNUKE_COUPON, percent_off: 100, duration: "forever", name: "つ抜け会員（紹介した会員が10人以上）" }); }
}
// 紹介でもらった無料の月を、Stripe の残高（次の請求から引かれる）に渡す
async function flushCredit(userId: string, customer: string) {
  const n = await rpc("billing_take_credit", { p_user: userId });
  if (!n) return;
  try {
    const price = await stripe.prices.retrieve(Deno.env.get("STRIPE_PRICE_ID")!);
    await stripe.customers.createBalanceTransaction(customer, { amount: -(price.unit_amount || 0) * n, currency: price.currency, description: `ご紹介の特典（${n}か月分無料）` });
  } catch (e) { await rpc("billing_add_credit", { p_user: userId, p_n: n }); throw e; }
}
// Stripe の購読の状態を、サーバーの会員の状態に反映する
export async function applySub(sub: Stripe.Subscription, userId?: string) {
  const end = (sub as any).current_period_end ?? (sub.items?.data?.[0] as any)?.current_period_end ?? sub.trial_end;
  return await rpc("billing_apply", { p: {
    customer: typeof sub.customer === "string" ? sub.customer : sub.customer.id, user_id: userId || sub.metadata?.user_id || null,
    sub_id: sub.id, status: sub.status, cancel_at_end: !!sub.cancel_at_period_end,
    period_end: end ? new Date(end * 1000).toISOString() : null } });
}
// 申し込みで登録したカードを確かめる：利用停止のカードなら購読を止め、無料期間を付けられないカード
// （プリペイド・ほかの人がこのカードで無料期間を使った）なら、無料期間を終わらせてすぐ課金にする
async function checkCard(sub: Stripe.Subscription, userId: string | null | undefined) {
  if (!userId || !["trialing", "active", "past_due", "incomplete"].includes(sub.status)) return;
  const pick = (x: any) => (typeof x === "string" ? x : x?.id) || null;
  let pmId = pick((sub as any).default_payment_method);
  if (!pmId) {
    const cust: any = await stripe.customers.retrieve(pick(sub.customer as any)!);
    pmId = pick(cust?.invoice_settings?.default_payment_method);
  }
  if (!pmId) return;
  const pm: any = await stripe.paymentMethods.retrieve(pmId);
  const card = pm?.card;
  if (!card?.fingerprint) return;
  const r: any = await rpc("billing_set_card", { p_user: userId, p_fp: card.fingerprint, p_funding: card.funding || "unknown" });
  if (r?.banned) { await stripe.subscriptions.cancel(sub.id); return; }
  if (!r?.trial_ok && sub.status === "trialing") await stripe.subscriptions.update(sub.id, { trial_end: "now", proration_behavior: "none" });
}
// 2か月後の同じ日の終わり（日本時間）
function trialEnd() {
  const d = new Date(Date.now() + 9 * 3600e3);
  const t = Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + TRIAL_MONTHS, d.getUTCDate(), 23, 59) - 9 * 3600e3;
  return Math.floor(t / 1000);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") || "" } } });
    const { data: { user } } = await sb.auth.getUser();
    if (!user) return json({ error: "ログインしてください" }, 401);
    const me = await (async () => { const { data, error } = await sb.rpc("billing_me"); if (error) throw new Error(error.message); return data; })();
    const { action, user_id: target } = await req.json().catch(() => ({ action: "" }));
    const { data: b } = await admin.from("billing").select("*").eq("user_id", user.id).single();
    const { data: prof } = await admin.from("profiles").select("tsunuke,nickname").eq("id", user.id).single();

    if (action === "checkout") {
      if (["active", "trialing", "past_due"].includes(b.sub_status)) return json({ error: "すでに申し込み済みです。「支払い方法の変更・解約」から手続きしてください" }, 400);
      let customer = b.stripe_customer;
      if (!customer) {
        const c = await stripe.customers.create({ email: user.email || undefined, name: prof?.nickname, metadata: { user_id: user.id } });
        customer = c.id; await rpc("billing_link_customer", { p_user: user.id, p_customer: customer });
      }
      await flushCredit(user.id, customer).catch(() => {});
      const tsunuke = !!prof?.tsunuke;
      if (tsunuke) await ensureCoupon();
      const session = await stripe.checkout.sessions.create({
        mode: "subscription", customer, client_reference_id: user.id, locale: "ja",
        line_items: [{ price: Deno.env.get("STRIPE_PRICE_ID")!, quantity: 1 }],
        payment_method_collection: "always",                         // 無料期間でもカードの登録は必須
        subscription_data: { metadata: { user_id: user.id }, ...(b.trial_used ? {} : { trial_end: trialEnd() }) },
        ...(tsunuke ? { discounts: [{ coupon: TSUNUKE_COUPON }] } : {}),
        // 支払いの画面の「申し込む」ボタンの近くに出す注意（無料期間を付けるときだけ）
        ...(b.trial_used ? {} : { custom_text: { submit: { message:
          "※プリペイド式のカードや、ほかのアカウントですでに無料期間を使ったカードでは、無料期間は付かず、申し込みのときに初回のお支払いになります。この画面の「無料」の表示は、カードを登録したあとで切り替わります。" } } }),
        success_url: APP_URL + "?billing=ok", cancel_url: APP_URL + "?billing=cancel",
      });
      return json({ url: session.url });
    }

    if (action === "admin_cancel") {                                // 管理者：利用停止にした人の購読をすぐ止める（それ以上請求しない）
      const { data: me2 } = await admin.from("profiles").select("role").eq("id", user.id).single();
      if (me2?.role !== "admin") return json({ error: "権限がありません" }, 403);
      const { data: tb } = await admin.from("billing").select("sub_id,sub_status").eq("user_id", target).maybeSingle();
      if (!tb?.sub_id || ["canceled", "incomplete_expired"].includes(tb.sub_status)) return json({ ok: true, none: true });
      await stripe.subscriptions.cancel(tb.sub_id);
      return json({ ok: true });
    }

    if (action === "portal") {
      if (!b.stripe_customer) return json({ error: "まだ申し込みがありません" }, 400);
      const s = await stripe.billingPortal.sessions.create({ customer: b.stripe_customer, return_url: APP_URL + "?billing=portal", locale: "ja" });
      return json({ url: s.url });
    }

    if (action === "sync") {                                       // 申し込みのあと・状態が変なとき：Stripe から読み直す
      if (b.stripe_customer) {
        const list = await stripe.subscriptions.list({ customer: b.stripe_customer, status: "all", limit: 1 });
        if (list.data[0]) { await applySub(list.data[0], user.id); await checkCard(list.data[0], user.id).catch(() => {}); }
        await flushCredit(user.id, b.stripe_customer).catch(() => {});
      }
      const { data } = await sb.rpc("billing_me");
      return json({ me: data });
    }
    return json({ me });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
