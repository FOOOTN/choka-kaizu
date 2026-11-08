// Stripe からの知らせ（支払い・解約・支払いの失敗）を受け取って、会員の状態を変える
// Supabase の Edge Functions に「stripe-webhook」という名前で置く。**JWT の確認はオフ**にする（Stripe はログインしないため。代わりに署名を確かめる）
// 必要な Secrets：STRIPE_SECRET_KEY・STRIPE_WEBHOOK_SECRET・STRIPE_PRICE_ID
import Stripe from "npm:stripe@17.7.0";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { httpClient: Stripe.createFetchHttpClient() });
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const TSUNUKE_COUPON = "tsunuke";

async function rpc(fn: string, args: Record<string, unknown>) {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
}
const custId = (c: string | { id: string } | null) => (typeof c === "string" ? c : c?.id) || "";

async function applySub(sub: Stripe.Subscription, userId?: string | null, paid = 0) {
  const end = (sub as any).current_period_end ?? (sub.items?.data?.[0] as any)?.current_period_end ?? sub.trial_end;
  return await rpc("billing_apply", { p: {
    customer: custId(sub.customer as any), user_id: userId || sub.metadata?.user_id || null,
    sub_id: sub.id, status: sub.status, cancel_at_end: !!sub.cancel_at_period_end, paid,
    period_end: end ? new Date(end * 1000).toISOString() : null } });
}
async function flushCredit(userId: string) {
  const { data: b } = await admin.from("billing").select("stripe_customer").eq("user_id", userId).single();
  if (!b?.stripe_customer) return;                                // まだ申し込んでいない紹介者：申し込んだときに渡す
  const n = await rpc("billing_take_credit", { p_user: userId });
  if (!n) return;
  try {
    const price = await stripe.prices.retrieve(Deno.env.get("STRIPE_PRICE_ID")!);
    await stripe.customers.createBalanceTransaction(b.stripe_customer, { amount: -(price.unit_amount || 0) * n, currency: price.currency, description: `ご紹介の特典（${n}か月分無料）` });
  } catch (e) { await rpc("billing_add_credit", { p_user: userId, p_n: n }); throw e; }
}
// 紹介者のつ抜け（支払い中の紹介が10人以上）に合わせて、紹介者の購読の割引を付け外しする
async function syncTsunuke(t: any) {
  if (!t?.sub_id || !["active", "trialing", "past_due"].includes(t.status)) return;
  const sub = await stripe.subscriptions.retrieve(t.sub_id);
  const has = !!(sub as any).discount || ((sub as any).discounts || []).length > 0;
  if (t.on && !has) {
    try { await stripe.coupons.retrieve(TSUNUKE_COUPON); }
    catch { await stripe.coupons.create({ id: TSUNUKE_COUPON, percent_off: 100, duration: "forever", name: "つ抜け会員（紹介した会員が10人以上）" }); }
    await stripe.subscriptions.update(t.sub_id, { discounts: [{ coupon: TSUNUKE_COUPON }] });
  } else if (!t.on && has) {
    await stripe.subscriptions.deleteDiscount(t.sub_id);
  }
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
async function after(out: any) {
  if (out?.referrer) await flushCredit(out.referrer);
  if (out?.tsunuke) await syncTsunuke(out.tsunuke);
}

Deno.serve(async (req) => {
  const sig = req.headers.get("stripe-signature");
  const body = await req.text();
  let ev: Stripe.Event;
  try {
    ev = await stripe.webhooks.constructEventAsync(body, sig || "", Deno.env.get("STRIPE_WEBHOOK_SECRET")!, undefined, Stripe.createSubtleCryptoProvider());
  } catch (e) {
    return new Response("署名が確かめられません: " + (e as Error).message, { status: 400 });
  }
  try {
    const o: any = ev.data.object;
    switch (ev.type) {
      case "checkout.session.completed": {
        if (o.mode !== "subscription" || !o.subscription) break;
        const sub = await stripe.subscriptions.retrieve(o.subscription);
        const out = await applySub(sub, o.client_reference_id);
        await after(out);
        await checkCard(sub, out?.user_id);
        break;
      }
      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted":
      case "customer.subscription.paused":
      case "customer.subscription.resumed": {
        // 届く順番が前後することがあるので、いつも Stripe から今の状態を読み直す
        const sub = await stripe.subscriptions.retrieve(o.id).catch(() => o);
        const out = await applySub(sub);
        await after(out);
        if (ev.type !== "customer.subscription.deleted") await checkCard(sub, out?.user_id);
        break;
      }
      case "invoice.paid":
      case "invoice.payment_failed": {
        const sid = o.subscription || o.parent?.subscription_details?.subscription;
        if (!sid) break;
        const sub = await stripe.subscriptions.retrieve(typeof sid === "string" ? sid : sid.id);
        // 実際にお金を払った請求だけを「支払い」と数える（無料期間・つ抜け・紹介の残高で0円の請求は数えない）
        const paid = ev.type === "invoice.paid" ? (o.amount_paid || 0) : 0;
        await after(await applySub(sub, null, paid));
        break;
      }
    }
    return new Response(JSON.stringify({ ok: true }), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    console.error(e);
    return new Response("処理できませんでした: " + (e as Error).message, { status: 500 });   // Stripe があとで送り直す
  }
});
