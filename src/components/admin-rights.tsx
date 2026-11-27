import { useCallback, useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { toast } from "@/lib/toast";
import { Wallet, Search, PlusCircle, MinusCircle, ShieldCheck, Settings2, Receipt, RefreshCw } from "lucide-react";

type User = { id:string; full_name:string|null; phone:string|null; email:string|null; governorate_key:string|null; roles:string[]; partner?:any; balance_iqd:number };
type Policy = { id:string; scope_type:string; scope_key:string|null; commission_rate_percent:number; commission_charge_percent:number; collection_event:string; free_trial_enabled:boolean; free_trial_days:number; new_users_only:boolean; is_enabled:boolean; starts_at:string|null; ends_at:string|null };
type Override = { id:string; user_id:string; commission_charge_percent:number; ends_at:string|null; created_at:string; profile?:{full_name?:string|null;phone?:string|null}|null };
type Collection = { id:string; payment_id:string; amount_iqd:number; provider_reference:string; created_at:string; reversed_amount_iqd?:number; net_amount_iqd?:number; reversal_reason?:string|null; reversed_at?:string|null; refund_review_pending?:boolean; payment_purpose?:string|null; payment_provider?:string|null };
type Revenue = { id:string; user_id:string; request_code?:string|null; revenue_type:string; assessed_iqd:number; collected_iqd:number; waived_iqd:number; status:string; metadata?:Record<string,any>; created_at:string; profile?:{full_name?:string|null;phone?:string|null}|null };

const durations = [{value:"1",label:"يوم"},{value:"7",label:"أسبوع"},{value:"30",label:"شهر"},{value:"90",label:"٣ أشهر"},{value:"180",label:"٦ أشهر"},{value:"365",label:"سنة"},{value:"permanent",label:"دائم"}];
const COMMISSION_CATEGORIES=[
 {role:"driver",label:"التكسي الاعتيادي",event:"taxi_acceptance"},
 {role:"large_driver",label:"الكيات والسيارات الكبيرة",event:"taxi_acceptance"},
 {role:"worker",label:"الفنيون ومقدمو الخدمات",event:"service_acceptance"},
 {role:"restaurant",label:"المطاعم",event:"order_acceptance"},
 {role:"hotel",label:"الفنادق",event:"order_acceptance"},
 {role:"store",label:"المتاجر",event:"order_acceptance"},
] as const;
const govLabels:Record<string,string>={baghdad:"بغداد",basra:"البصرة",nineveh:"نينوى",erbil:"أربيل",sulaymaniyah:"السليمانية",duhok:"دهوك",kirkuk:"كركوك",najaf:"النجف",karbala:"كربلاء",babil:"بابل",anbar:"الأنبار",diyala:"ديالى",saladin:"صلاح الدين",wasit:"واسط",dhiqar:"ذي قار",maysan:"ميسان",muthanna:"المثنى",qadisiyah:"القادسية"};

export default function AdminRights() {
  const [tab,setTab]=useState<"wallet"|"special"|"policies"|"revenue"|"refunds">("wallet");
  const [query,setQuery]=useState(""); const [users,setUsers]=useState<User[]>([]); const [selected,setSelected]=useState<User|null>(null);
  const [amount,setAmount]=useState(""); const [note,setNote]=useState(""); const [kind,setKind]=useState<"debit"|"credit">("debit");
  const [chargePercent,setChargePercent]=useState("0"); const [duration,setDuration]=useState("30"); const [overrideReason,setOverrideReason]=useState("إعفاء أو تخفيض عمولة بموافقة الإدارة");
  const [policies,setPolicies]=useState<Policy[]>([]); const [overrides,setOverrides]=useState<Override[]>([]); const [revenue,setRevenue]=useState<Revenue[]>([]); const [collections,setCollections]=useState<Collection[]>([]); const [summary,setSummary]=useState<any>({});
  const [commissionRates,setCommissionRates]=useState<Record<string,string>>({driver:"0",large_driver:"0",worker:"0",restaurant:"0",hotel:"0",store:"0"});
  const [busy,setBusy]=useState(false); const [loading,setLoading]=useState(false); const [error,setError]=useState("");
  const [refundCases,setRefundCases]=useState<any[]>([]);
  const [canViewRefunds,setCanViewRefunds]=useState(false);
  const [canDecideRefunds,setCanDecideRefunds]=useState(false);
  const [refundNotes,setRefundNotes]=useState<Record<string,string>>({});
  const [refundReferences,setRefundReferences]=useState<Record<string,string>>({});
  const [refundFilter,setRefundFilter]=useState("pending_review");
  const [refundBusyId,setRefundBusyId]=useState<string|null>(null);


  const invoke=useCallback(async(body:Record<string,unknown>)=>{
    const {data,error:callError}=await supabase.functions.invoke("admin-rights",{body});
    if(callError) throw new Error(callError.message||"تعذر الاتصال بحقوق ممنون");
    if(data?.error) throw new Error(data.error);
    return data;
  },[]);

  const load=useCallback(async()=>{
    setLoading(true);setError("");
    try{const data=await invoke({action:"list"});const loadedPolicies=data.policies??[];setPolicies(loadedPolicies);setCommissionRates(Object.fromEntries(COMMISSION_CATEGORIES.map(category=>{const specific=loadedPolicies.find((p:Policy)=>p.scope_type==="role"&&p.scope_key===category.role&&p.collection_event===category.event&&p.is_enabled)??loadedPolicies.find((p:Policy)=>p.scope_type==="role"&&p.scope_key===category.role&&p.collection_event===category.event);const globalPolicy=loadedPolicies.find((p:Policy)=>p.scope_type==="global"&&p.collection_event===category.event&&p.is_enabled)??loadedPolicies.find((p:Policy)=>p.scope_type==="global"&&p.collection_event===category.event);return [category.role,String(specific?.commission_rate_percent??globalPolicy?.commission_rate_percent??0)];})));setOverrides(data.overrides??[]);setRevenue(data.revenue??[]);setCollections(data.collections??[]);setSummary(data.summary??{});}
    catch(e:any){setError(String(e?.message||"تعذر تحميل إعدادات الحقوق"));}finally{setLoading(false);}
  },[invoke]);
  useEffect(()=>{if(tab==="policies"||tab==="revenue"||tab==="special") void load();},[tab,load]);
  const loadRefundCases=useCallback(async()=>{
    setLoading(true);setError("");setCanViewRefunds(false);setCanDecideRefunds(false);setRefundCases([]);
    try{
      const {data,error:callError}=await supabase.functions.invoke("admin-finance",{body:{action:"refund_cases_list"}});
      if(callError) throw new Error(callError.message||"تعذر تحميل طلبات الاسترداد");
      if(data?.error) throw new Error(String(data.error));
      setRefundCases(data?.cases??[]);
      setCanViewRefunds(data?.can_view===true);
      setCanDecideRefunds(data?.can_decide===true);
    }catch(e:any){setError(String(e?.message||"تعذر تحميل طلبات الاسترداد"));}
    finally{setLoading(false);}
  },[]);
  useEffect(()=>{if(tab==="refunds") void loadRefundCases();},[tab,loadRefundCases]);

  const decideRefundCase=async(refundCaseId:string,decision:"approved"|"rejected")=>{
    if(refundBusyId)return;
    const note=(refundNotes[refundCaseId]||"").trim();
    if(decision==="rejected"&&note.length<2){toast.error("اكتب سبب رفض طلب الاسترداد");return;}
    setRefundBusyId(refundCaseId);
    try{
      const {data,error:callError}=await supabase.functions.invoke("admin-finance",{body:{action:"refund_case_decide",refund_case_id:refundCaseId,decision,note}});
      if(callError)throw new Error(callError.message||"تعذر حفظ القرار");
      if(data?.error)throw new Error(String(data.error));
      toast.success(decision==="approved"?"موافقة مبدئية؛ لم يتم تحويل مبلغ بعد":"تم رفض الطلب وتوثيق السبب");
      await loadRefundCases();
    }catch(e:any){toast.error(String(e?.message||"تعذر حفظ القرار"));}
    finally{setRefundBusyId(null);}
  };
  const markRefundCasePaid=async(refundCaseId:string)=>{
    if(refundBusyId)return;
    const reference=(refundReferences[refundCaseId]||"").trim();
    if(reference.length<2){toast.error("أدخل مرجع عملية الاسترداد بعد إعادة المبلغ فعلياً");return;}
    setRefundBusyId(refundCaseId);
    try{
      const {data,error:callError}=await supabase.functions.invoke("admin-finance",{body:{action:"refund_case_mark_refunded",refund_case_id:refundCaseId,refund_reference:reference}});
      if(callError)throw new Error(callError.message||"تعذر تسجيل الاسترداد");
      if(data?.error)throw new Error(String(data.error));
      toast.success("تم تسجيل الاسترداد الفعلي");
      setRefundReferences(current=>({...current,[refundCaseId]:""}));
      await loadRefundCases();
    }catch(e:any){toast.error(String(e?.message||"تعذر تسجيل الاسترداد"));}
    finally{setRefundBusyId(null);}
  };


  const searchUsers=async()=>{
    if(query.trim().length<2){toast.error("اكتب حرفين أو أكثر للبحث");return;}
    setBusy(true);
    try{const data=await invoke({action:"search_users",query:query.trim()});setUsers(data.users??[]);setSelected(null);}
    catch(e:any){toast.error(String(e?.message||"تعذر البحث"));}finally{setBusy(false);}
  };

  const adjustWallet=async()=>{
    if(!selected||!/^\d+$/.test(amount)||Number(amount)<=0||!note.trim()){toast.error("اختار مستخدماً واكتب مبلغاً وسبباً صحيحاً");return;}
    setBusy(true);
    try{
      const idempotency=globalThis.crypto?.randomUUID?.()||("admin-"+Date.now()+"-"+selected.id);
      const result=await invoke({action:"wallet_adjust",user_id:selected.id,amount_iqd:Number(amount),type:kind,note:note.trim(),idempotency_key:idempotency});
      toast.success("تم تسجيل الحركة. الرصيد الجديد: "+Number(result.result?.balance_iqd??0).toLocaleString("ar-IQ")+" د.ع");
      setAmount("");setNote("");await searchUsers();
    }catch(e:any){toast.error(String(e?.message||"تعذر تعديل المحفظة"));}finally{setBusy(false);}
  };

  const saveOverride=async()=>{
    if(!selected||!Number.isFinite(Number(chargePercent))||Number(chargePercent)<0||Number(chargePercent)>100||!overrideReason.trim()){toast.error("تحقق من المستخدم والنسبة والسبب");return;}
    const end=duration==="permanent"?null:new Date(Date.now()+Number(duration)*86400000).toISOString();
    setBusy(true);
    try{await invoke({action:"save_override",user_id:selected.id,charge_percent:Number(chargePercent),starts_at:new Date().toISOString(),ends_at:end,reason:overrideReason.trim()});toast.success("تم حفظ الميزة الخاصة");await load();}
    catch(e:any){toast.error(String(e?.message||"تعذر حفظ الميزة"));}finally{setBusy(false);}
  };

  const revokeOverride=async(id:string)=>{
    if(!confirm("تأكيد إلغاء الميزة الخاصة؟")) return;
    try{await invoke({action:"revoke_override",override_id:id});toast.success("تم إلغاء الميزة");await load();}
    catch(e:any){toast.error(String(e?.message||"تعذر إلغاء الميزة"));}
  };

  const saveCategoryPolicy=async(category:typeof COMMISSION_CATEGORIES[number])=>{
    const percent=Number(commissionRates[category.role]??"0");
    if(!Number.isFinite(percent)||percent<0||percent>100){toast.error("اكتب نسبة من 0 إلى 100");return;}
    setBusy(true);
    try{await invoke({action:"save_policy",scope_type:"role",scope_key:category.role,commission_rate_percent:percent,commission_charge_percent:100,collection_event:category.event,free_trial_enabled:false,free_trial_days:0,new_users_only:false,is_enabled:true,starts_at:new Date().toISOString(),ends_at:null});toast.success("انحفظت نسبة "+category.label+" وحدها");await load();}
    catch(e:any){toast.error(String(e?.message||"تعذر حفظ نسبة الاستقطاع"));}finally{setBusy(false);}
  };

  const revenueLabel:Record<string,string>={taxi_commission:"عمولة التكسي",service_commission:"عمولة الفني",order_commission:"عمولة طلب شريك",complaint_deduction:"استقطاع شكوى",wallet_debt_collection:"تحصيل دين المحفظة",admin_credit_reversal:"تسوية إدارية"};
  const statusLabel:Record<string,string>={accrued:"مستحق",partially_collected:"محصل جزئياً",collected:"محصل",void:"ملغى",partially_waived:"معفى جزئياً",waived:"مغلق بالإعفاء"};
  const categoryLabel=(u:User)=>{
    const value=String(u.partner?.partner_type||u.partner?.business_vertical||"").toLowerCase();
    if(value.includes("restaurant")||value.includes("food"))return "مطعم";
    if(value.includes("hotel")||value.includes("hospitality"))return "فندق";
    if(value.includes("store")||value.includes("shop")||value.includes("grocery"))return "متجر";
    const labels:Record<string,string>={driver:"صاحب تكسي",large_driver:"تكسي كبير",worker:"فني",customer:"زبون",restaurant:"مطعم",hotel:"فندق",store:"متجر"};
    return (u.roles??[]).map(r=>labels[r]||r).join("، ")||"مستخدم";
  };
  return <section dir="rtl" className="space-y-4">
    <header><h2 className="text-xl font-black flex items-center gap-2"><ShieldCheck className="h-5 w-5 text-primary"/> حقوق ممنون</h2><p className="text-xs text-muted-foreground mt-1">المحافظ والعمولات والإعفاءات وسجل إيرادات ممنون.</p></header>
    <div className="flex flex-wrap gap-2">{[
      ["wallet","استقطاع الشكاوي وإضافة الرصيد",Wallet],["special","مستخدمون بميزات خاصة",ShieldCheck],["policies","إعدادات الاستقطاع",Settings2],["revenue","الإيرادات",Receipt],["refunds","طلبات الإلغاء والاسترداد",RefreshCw]
    ].map(([key,label,Icon]:any)=><button key={key} onClick={()=>setTab(key)} className={`rounded-xl px-3 py-2 text-xs font-bold flex items-center gap-2 ${tab===key?"bg-primary text-primary-foreground":"glass text-muted-foreground"}`}><Icon className="h-4 w-4"/>{label}</button>)}</div>
    {(tab==="wallet"||tab==="special")&&<div className="glass rounded-2xl p-4 space-y-3">
      <h3 className="font-black text-sm">البحث عن مستخدم</h3>
      <div className="flex gap-2"><input value={query} onChange={e=>setQuery(e.target.value)} placeholder="الاسم أو رقم الهاتف أو البريد" className="min-w-0 flex-1 rounded-xl border border-border bg-background p-3 text-xs"/><button onClick={()=>void searchUsers()} disabled={busy} className="rounded-xl bg-primary text-primary-foreground px-4"><Search className="h-4 w-4"/></button></div>
      <div className="space-y-2 max-h-64 overflow-y-auto">{users.map(u=><button key={u.id} onClick={()=>setSelected(u)} className={`w-full text-right rounded-xl border p-3 ${selected?.id===u.id?"border-primary bg-primary/5":"border-border bg-card"}`}><div className="font-black text-xs">{u.full_name||"مستخدم ممنون"}</div><div className="text-[10px] text-muted-foreground">{u.phone||u.email||u.id} · {categoryLabel(u)} · {govLabels[u.governorate_key||""]||u.governorate_key||"بلا محافظة"}</div><div className="text-[10px] mt-1">رصيد المحفظة: <b>{Number(u.balance_iqd).toLocaleString("ar-IQ")} د.ع</b></div></button>)}</div>
      {selected&&<div className="rounded-xl border border-primary/30 bg-primary/5 p-3 space-y-3">
        <div className="font-black text-sm">{selected.full_name||selected.phone}</div>
        {tab==="wallet"?<>
          <div className="flex gap-2"><button onClick={()=>setKind("debit")} className={`flex-1 rounded-xl p-2 text-xs font-bold ${kind==="debit"?"bg-destructive text-white":"bg-muted"}`}><MinusCircle className="inline h-4 w-4 ml-1"/>استقطاع شكوى</button><button onClick={()=>setKind("credit")} className={`flex-1 rounded-xl p-2 text-xs font-bold ${kind==="credit"?"bg-emerald-600 text-white":"bg-muted"}`}><PlusCircle className="inline h-4 w-4 ml-1"/>إضافة رصيد</button></div>
          <input value={amount} onChange={e=>setAmount(e.target.value)} inputMode="numeric" placeholder="المبلغ بالدينار العراقي" className="w-full rounded-xl border border-border bg-background p-3 text-xs"/>
          <input value={note} onChange={e=>setNote(e.target.value)} placeholder="سبب العملية (إلزامي)" className="w-full rounded-xl border border-border bg-background p-3 text-xs"/>
          <button disabled={busy} onClick={()=>void adjustWallet()} className="w-full rounded-xl bg-primary text-primary-foreground p-3 text-xs font-black">{busy?"جارٍ التنفيذ...":kind==="debit"?"تأكيد الاستقطاع":"تأكيد إضافة الرصيد"}</button>
        </>:<>
          <label className="block text-xs font-bold">نسبة تحصيل عمولة ممنون</label>
          <input value={chargePercent} onChange={e=>setChargePercent(e.target.value)} inputMode="decimal" className="w-full rounded-xl border border-border bg-background p-3 text-xs" placeholder="من 0 إلى 100"/>
          <label className="block text-xs font-bold">مدة الميزة</label>
          <select value={duration} onChange={e=>setDuration(e.target.value)} className="w-full rounded-xl border border-border bg-background p-3 text-xs">{durations.map(d=><option key={d.value} value={d.value}>{d.label}</option>)}</select>
          <input value={overrideReason} onChange={e=>setOverrideReason(e.target.value)} className="w-full rounded-xl border border-border bg-background p-3 text-xs" placeholder="سبب الميزة"/>
          <button disabled={busy} onClick={()=>void saveOverride()} className="w-full rounded-xl bg-primary text-primary-foreground p-3 text-xs font-black">حفظ الميزة الخاصة</button>
        </>}
      </div>}
      {tab==="special"&&<div className="border-t border-border pt-3 space-y-2"><h4 className="font-black text-xs">الإعفاءات والميزات السارية</h4>{overrides.map(o=><div key={o.id} className="rounded-xl bg-card border border-border p-3 flex items-center justify-between gap-2"><div className="min-w-0"><b className="text-xs">{o.profile?.full_name||o.profile?.phone||"مستخدم"}</b><p className="text-[10px] text-muted-foreground">تحصيل {o.commission_charge_percent}% · {o.ends_at?new Date(o.ends_at).toLocaleDateString("ar-IQ"):"دائم"}</p></div><button onClick={()=>void revokeOverride(o.id)} className="rounded-lg bg-destructive/10 text-destructive px-3 py-2 text-[10px] font-bold">إلغاء</button></div>)}{!overrides.length&&<p className="text-[10px] text-muted-foreground">لا توجد ميزات خاصة سارية</p>}</div>}
    </div>}
    {tab==="policies"&&<div className="glass rounded-2xl p-4 space-y-3">
      <div className="flex justify-between items-center"><div><h3 className="font-black text-sm">نسبة الاستقطاع حسب الفئة</h3><p className="text-[10px] text-muted-foreground mt-1">كل فئة إلها نسبة مستقلة وزر حفظ خاص. نسبة 0٪ تعني عدم استقطاع عمولة من الفئة.</p></div><button onClick={()=>void load()} className="text-xs text-primary"><RefreshCw className="inline h-3.5 w-3.5 ml-1"/>تحديث</button></div>
      {COMMISSION_CATEGORIES.map(category=>{const current=policies.find(p=>p.scope_type==="role"&&p.scope_key===category.role&&p.collection_event===category.event);return <div key={category.role} className="rounded-xl border border-border bg-card p-3 space-y-2"><h4 className="font-black text-xs">{category.label}</h4><label className="block text-xs font-bold">نسبة استقطاع ممنون من قيمة الطلب (%)<input value={commissionRates[category.role]??"0"} onChange={e=>setCommissionRates(old=>({...old,[category.role]:e.target.value}))} inputMode="decimal" className="mt-1 w-full rounded-xl border border-border bg-background p-3 text-xs" placeholder="0 إلى 100"/></label><p className="text-[10px] text-muted-foreground">{current?"آخر نسبة محفوظة: "+Number(current.commission_rate_percent||0)+"٪ · "+(current.is_enabled?"مفعّلة":"متوقفة"):"ماكو تخصيص مستقل محفوظ؛ تُستخدم النسبة العامة إن وجدت."}</p><button disabled={busy} onClick={()=>void saveCategoryPolicy(category)} className="w-full rounded-xl bg-primary text-primary-foreground p-3 text-xs font-black">{busy?"جارٍ الحفظ...":"حفظ نسبة "+category.label+" فقط"}</button></div>;})}
      <p className="text-[10px] text-muted-foreground">ماكو نسبة خصم أو تحصيل إضافية بهذا النموذج؛ النظام يحسب الاستقطاع من النسبة الوحيدة المحددة لكل فئة. كل حفظ يغيّر الفئة المحددة فقط.</p>
    </div>}
    {tab==="revenue"&&<div className="glass rounded-2xl p-4 space-y-3"><div className="flex justify-between items-center"><h3 className="font-black text-sm">دفتر إيرادات ممنون</h3><button onClick={()=>void load()} className="text-xs text-primary">تحديث</button></div><div className="grid grid-cols-1 sm:grid-cols-3 gap-2"><div className="rounded-xl bg-primary/10 p-3"><p className="text-[10px] text-muted-foreground">إجمالي إيرادات ممنون المحصلة</p><b className="text-lg">{Number(summary.collected_iqd||0).toLocaleString("ar-IQ")} د.ع</b></div><div className="rounded-xl bg-muted p-3"><p className="text-[10px] text-muted-foreground">منها تحصيل ديون جديدة عبر زين كاش</p><b className="text-lg">{Number(summary.zaincash_debt_collected_iqd||0).toLocaleString("ar-IQ")} د.ع</b></div><div className="rounded-xl bg-muted p-3"><p className="text-[10px] text-muted-foreground">ديون مستحقة لممنون</p><b className="text-lg">{Number(summary.outstanding_iqd||0).toLocaleString("ar-IQ")} د.ع</b></div></div><h4 className="font-black text-xs">تحصيلات زين كاش المؤكدة</h4>{collections.map(x=><div key={x.id} className="rounded-xl bg-card border border-border p-3"><b className="text-xs">{Number(x.amount_iqd).toLocaleString("ar-IQ")} د.ع</b><p className="text-[10px] text-muted-foreground">{x.payment_purpose==="wallet_topup"?"تحصيل من شحن محفظة":x.payment_purpose==="service_request"?"عمولة من دفعة طلب خدمة":"تحصيل"} · {x.payment_provider||"—"} · مرجع: {x.provider_reference} · {new Date(x.created_at).toLocaleString("ar-IQ")}</p>{x.refund_review_pending&&<p className="text-[10px] text-amber-700 font-black">معلّق لحين حسم طلب الاسترداد</p>}{Number(x.reversed_amount_iqd||0)>0&&<p className="text-[10px] text-amber-700">عكس قيد/استرداد: {Number(x.reversed_amount_iqd).toLocaleString("ar-IQ")} د.ع · الصافي المحتسب {Number(x.net_amount_iqd||0).toLocaleString("ar-IQ")} د.ع · {x.reversal_reason||"قيد معكوس"}</p>}</div>)}<h4 className="font-black text-xs pt-2">العمولات والاستقطاعات</h4>{revenue.map(r=><div key={r.id} className="rounded-xl bg-card border border-border p-3"><div className="font-black text-xs">{r.profile?.full_name||r.profile?.phone||"مستخدم"}</div><div className="text-[10px] text-muted-foreground">{revenueLabel[r.revenue_type]||r.revenue_type} · {new Date(r.created_at).toLocaleString("ar-IQ")}{r.request_code?" · رقم الطلب "+r.request_code:""}</div><div className="text-xs mt-1">مستحق {Number(r.assessed_iqd).toLocaleString("ar-IQ")} د.ع · محصل {Number(r.collected_iqd).toLocaleString("ar-IQ")} د.ع · معفى {Number(r.waived_iqd).toLocaleString("ar-IQ")} د.ع</div><div className={"text-[10px] mt-1 "+(r.metadata?.refund_review_pending?"text-amber-700 font-black":"")}>{r.metadata?.refund_review_pending?"معلّق لحين حسم طلب الاسترداد":statusLabel[r.status]||r.status}</div></div>)}{!revenue.length&&<p className="text-xs text-muted-foreground">لا توجد إيرادات مسجلة حالياً</p>}</div>}
    {tab==="refunds"&&<div className="glass rounded-2xl p-4 space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div><h3 className="font-black text-sm">طلبات إلغاء واسترداد زين كاش</h3><p className="text-[10px] text-muted-foreground mt-1">المبالغ قيد المراجعة ليست إيراداً نهائياً. لا يوجد تحويل تلقائي.</p></div>
        <button onClick={()=>void loadRefundCases()} className="text-xs text-primary"><RefreshCw className="inline h-3.5 w-3.5 ml-1"/>تحديث</button>
      </div>
      {!canViewRefunds&&!loading?<p className="text-xs text-muted-foreground">ما عندك صلاحية عرض طلبات الاسترداد. يلزم منح صلاحية finance.refund.read.</p>:<>
        <div className="flex flex-wrap gap-2">{[["pending_review","بانتظار المراجعة"],["approved","موافق عليه"],["rejected","مرفوض"],["refunded","مسترد فعلياً"],["all","الكل"]].map(([value,label])=><button key={value} onClick={()=>setRefundFilter(value)} className={`rounded-full border px-3 py-2 text-[10px] font-bold ${refundFilter===value?"bg-primary text-primary-foreground border-primary":"border-border bg-background"}`}>{label}</button>)}</div>
        <div className="space-y-3">
          {refundCases.filter(row=>refundFilter==="all"||row.status===refundFilter).map(row=><article key={row.id} className="rounded-xl border border-border bg-card p-3 space-y-2">
            <div className="flex flex-wrap items-center justify-between gap-2"><b className="text-xs">{row.request?.request_code||("#"+String(row.request_id).slice(0,8))}</b><span className="rounded-full bg-muted px-2 py-1 text-[10px]">{row.status==="pending_review"?"بانتظار المراجعة":row.status==="approved"?"موافقة مبدئية":row.status==="rejected"?"مرفوض":"تم الاسترداد"}</span></div>
            <div className="grid grid-cols-2 sm:grid-cols-3 gap-2 text-[10px]">
              <div><span className="block text-muted-foreground">الزبون</span><b>{row.customer?.full_name||"—"}</b></div>
              <div><span className="block text-muted-foreground">الهاتف</span><b dir="ltr">{row.customer?.phone||"—"}</b></div>
              <div><span className="block text-muted-foreground">المبلغ</span><b>{Number(row.amount_iqd||0).toLocaleString("ar-IQ")} د.ع</b></div>
              <div><span className="block text-muted-foreground">مرجع الدفع</span><b dir="ltr" className="break-all">{row.payment?.gateway_transaction_id||"—"}</b></div>
              <div><span className="block text-muted-foreground">تاريخ الإلغاء</span><b>{new Date(row.created_at).toLocaleString("ar-IQ")}</b></div>
              <div><span className="block text-muted-foreground">بوابة الدفع</span><b>{row.payment?.provider||"—"} · {row.payment?.currency||"IQD"}</b></div><div><span className="block text-muted-foreground">تاريخ الدفع</span><b>{row.payment?.paid_at?new Date(row.payment.paid_at).toLocaleString("ar-IQ"):"—"}</b></div><div><span className="block text-muted-foreground">حالة الدفع</span><b>{row.payment?.status||"—"}</b></div>
            </div>
            <p className="rounded-lg bg-muted p-2 text-[10px]"><b>سبب الإلغاء: </b>{row.cancellation_reason||"لم يُذكر سبب"}</p>
            {row.decision_note&&<p className="rounded-lg bg-muted p-2 text-[10px]"><b>ملاحظة القرار: </b>{row.decision_note}</p>}
            {row.refund_reference&&<p className="text-[10px] text-emerald-700"><b>مرجع الاسترداد الفعلي: </b><span dir="ltr">{row.refund_reference}</span></p>}
            {row.status==="pending_review"&&canDecideRefunds&&<div className="space-y-2 border-t border-border pt-2">
              <textarea value={refundNotes[row.id]||""} onChange={e=>setRefundNotes(current=>({...current,[row.id]:e.target.value}))} maxLength={500} placeholder="ملاحظة المراجعة أو سبب الرفض (إلزامي عند الرفض)" className="w-full min-h-16 rounded-lg border border-border bg-background p-2 text-xs"/>
              <div className="flex gap-2"><button disabled={refundBusyId===row.id} onClick={()=>void decideRefundCase(row.id,"approved")} className="flex-1 rounded-lg bg-emerald-600 p-2.5 text-[10px] font-black text-white disabled:opacity-50">موافقة مبدئية</button><button disabled={refundBusyId===row.id} onClick={()=>void decideRefundCase(row.id,"rejected")} className="flex-1 rounded-lg bg-red-600 p-2.5 text-[10px] font-black text-white disabled:opacity-50">رفض الطلب</button></div>
            </div>}
            {row.status==="approved"&&canDecideRefunds&&<div className="space-y-2 border-t border-border pt-2"><p className="text-[10px] text-muted-foreground">بعد إعادة المبلغ يدوياً عبر زين كاش، أدخل رقم المرجع. لا تؤكد قبل تنفيذ التحويل فعلياً.</p><input value={refundReferences[row.id]||""} onChange={e=>setRefundReferences(current=>({...current,[row.id]:e.target.value}))} maxLength={120} placeholder="رقم مرجع عملية الاسترداد" className="w-full rounded-lg border border-border bg-background p-2.5 text-xs"/><button disabled={refundBusyId===row.id} onClick={()=>void markRefundCasePaid(row.id)} className="w-full rounded-lg bg-primary p-2.5 text-xs font-black text-primary-foreground disabled:opacity-50">تأكيد أن المبلغ أُعيد فعلياً</button></div>}
            {!canDecideRefunds&&row.status!=="refunded"&&<p className="text-[10px] text-muted-foreground">يمكنك الاطلاع فقط؛ لا تملك صلاحية اعتماد أو تسجيل الاسترداد.</p>}
            {row.events?.length>0&&<div className="border-t border-border pt-2 space-y-1 text-[10px] text-muted-foreground"><b>سجل الإجراءات</b>{row.events.map((event:any)=><p key={event.id}>{event.event_type==="opened"?"فتح طلب المراجعة":event.event_type==="approved"?"موافقة مبدئية":event.event_type==="rejected"?"رفض الطلب":"تسجيل الاسترداد الفعلي"} · {new Date(event.created_at).toLocaleString("ar-IQ")} · {event.actor?.full_name||event.actor?.phone||"النظام"}{event.note?" · "+event.note:""}{event.reference?" · المرجع "+event.reference:""}</p>)}</div>}
          </article>)}
          {refundCases.filter(row=>refundFilter==="all"||row.status===refundFilter).length===0&&<p className="text-xs text-muted-foreground">لا توجد طلبات استرداد بهذا التصنيف حالياً.</p>}
        </div>
      </>}
    </div>}
    {!!error&&<p className="text-xs text-destructive">{error}</p>}
    {loading&&<p className="text-xs text-muted-foreground">جارٍ تحديث البيانات...</p>}
  </section>;
}
