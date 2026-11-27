import { useCallback, useEffect, useMemo, useState } from "react";
import { BellRing, Check, MapPin, RefreshCw, Save, X } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { toast } from "@/lib/toast";
import { GOVERNORATES } from "@/lib/governorates";

type Mode = "auto" | "notify" | "off";
type Zone = {
  id: string; governorate_key: string; city_name: string; neighborhood_name: string; category_key: string;
  center_lat: number; center_lng: number; radius_km: number; min_surcharge_percent: number;
  max_surcharge_percent: number; mode: Mode; enabled: boolean; active_percent: number;
  observed_providers: number; active_providers: number; pending_requests: number; demand_per_provider: number;
  last_reason: string | null; last_calculated_at: string | null;
};
type Recommendation = {
  id: string; governorate_key: string; city_name: string; neighborhood_name: string; category_key: string;
  center_lat: number; center_lng: number; radius_km: number; suggested_percent: number;
  observed_providers: number; active_providers: number; pending_requests: number; demand_per_provider: number;
  weather: Record<string, unknown>; reason: string; status: string; created_at: string;
};
const TAXI = [
  ["taxi:economy", "تكسي اقتصادي"], ["taxi:premium", "تكسي متميز"],
  ["taxi:luxury", "تكسي فاخر"], ["taxi:large", "السيارات الكبيرة والناقل"],
] as const;
const labels = Object.fromEntries(GOVERNORATES.map(g => [g.key, g.name])) as Record<string,string>;
const categoryName = (key: string, services: Array<{slug:string;name_ar:string}>) =>
  TAXI.find(x=>x[0]===key)?.[1] || services.find(s=>"service:"+s.slug===key)?.name_ar || key;

export default function AdminRegionalPeakPricing() {
  const [zones,setZones]=useState<Zone[]>([]);
  const [recommendations,setRecommendations]=useState<Recommendation[]>([]);
  const [services,setServices]=useState<Array<{slug:string;name_ar:string}>>([]);
  const [allowed,setAllowed]=useState(false);
  const [loading,setLoading]=useState(true);
  const [saving,setSaving]=useState(false);
  const [deciding,setDeciding]=useState<string|null>(null);
  const [editingId,setEditingId]=useState<string|null>(null);
  const [governorate,setGovernorate]=useState("najaf");
  const [city,setCity]=useState("");
  const [neighborhood,setNeighborhood]=useState("");
  const [category,setCategory]=useState("taxi:economy");
  const [lat,setLat]=useState("32.0259");
  const [lng,setLng]=useState("44.3462");
  const [radius,setRadius]=useState("3");
  const [minimum,setMinimum]=useState("5");
  const [maximum,setMaximum]=useState("20");
  const [mode,setMode]=useState<Mode>("off");
  const [enabled,setEnabled]=useState(false);

  const load=useCallback(async()=>{
    setLoading(true);
    const [permission,z,r,s]=await Promise.all([
      (supabase as any).rpc("admin_has_any_pricing_permission"),
      (supabase as any).from("regional_peak_pricing_settings").select("*").order("governorate_key").order("city_name").order("neighborhood_name"),
      (supabase as any).from("regional_peak_recommendations").select("*").eq("status","pending").order("created_at",{ascending:false}).limit(30),
      (supabase as any).from("services").select("slug,name_ar").order("sort_order"),
    ]);
    setAllowed(!permission.error && permission.data===true);
    if(z.error) toast.error("تعذر تحميل إعدادات المناطق: "+z.error.message);
    if(r.error) toast.error("تعذر تحميل التوصيات: "+r.error.message);
    if(s.error) toast.error("تعذر تحميل فئات الخدمات: "+s.error.message);
    setZones((z.data??[]) as Zone[]); setRecommendations((r.data??[]) as Recommendation[]); setServices(s.data??[]);
    setLoading(false);
  },[]);
  useEffect(()=>{void load();},[load]);

  const categories=useMemo(()=>[...TAXI.map(([value,label])=>({value,label})),...services.map(s=>({value:"service:"+s.slug,label:s.name_ar}))],[services]);
  function resetForm(){
    setEditingId(null);setCity("");setNeighborhood("");setCategory("taxi:economy");
    const g=GOVERNORATES.find(x=>x.key===governorate)??GOVERNORATES[0];setLat(String(g.lat));setLng(String(g.lng));
    setRadius("3");setMinimum("5");setMaximum("20");setMode("off");setEnabled(false);
  }
  function editZone(z:Zone){
    setEditingId(z.id);setGovernorate(z.governorate_key);setCity(z.city_name);setNeighborhood(z.neighborhood_name);
    setCategory(z.category_key);setLat(String(z.center_lat));setLng(String(z.center_lng));setRadius(String(z.radius_km));
    setMinimum(String(z.min_surcharge_percent));setMaximum(String(z.max_surcharge_percent));setMode(z.mode);setEnabled(z.enabled);
    window.scrollTo({top:0,behavior:"smooth"});
  }
  async function save(){
    const a=Number(lat),b=Number(lng),r=Number(radius),lo=Number(minimum),hi=Number(maximum);
    if(!city.trim()||!Number.isFinite(a)||!Number.isFinite(b)||!Number.isFinite(r)||!Number.isFinite(lo)||!Number.isFinite(hi)||a<29||a>38||b<38||b>49||r<0.1||r>40||lo<0||hi>100||lo>hi){
      toast.error("راجع اسم المدينة والإحداثيات ونطاق المنطقة والنسب قبل الحفظ.");return;
    }
    if(mode==="off"&&enabled){toast.error("اختيار الإيقاف لا يمكن أن يكون مفعّلاً.");return;}
    setSaving(true);
    const {error}=await (supabase as any).rpc("admin_save_regional_peak_pricing",{
      p_governorate_key:governorate,p_city_name:city.trim(),p_neighborhood_name:neighborhood.trim(),
      p_category_key:category,p_center_lat:a,p_center_lng:b,p_radius_km:r,
      p_min_surcharge_percent:lo,p_max_surcharge_percent:hi,p_mode:mode,p_enabled:enabled,
    });
    setSaving(false);
    if(error) toast.error("تعذر حفظ الإعدادات: "+error.message);
    else {toast.success("انحفظ إعداد المنطقة والفئة.");resetForm();await load();}
  }
  async function decide(id:string,approve:boolean){
    setDeciding(id);
    const {error}=await (supabase as any).rpc("admin_decide_regional_peak_recommendation",{p_recommendation_id:id,p_approve:approve});
    setDeciding(null);
    if(error)toast.error("تعذر تنفيذ القرار: "+error.message);
    else{toast.success(approve?"تمت الموافقة لمدة 30 دقيقة.":"تم رفض التوصية.");await load();}
  }

  if(loading)return <div className="p-5 text-sm text-muted-foreground">جارٍ تحميل إعدادات الذروة الإقليمية…</div>;
  if(!allowed)return <div className="rounded-2xl border p-5 text-sm text-muted-foreground">تحتاج صلاحية إدارة الذروة للمحافظة المطلوبة.</div>;
  return <section dir="rtl" className="space-y-5 rounded-2xl border border-border bg-card p-4">
    <header className="flex flex-wrap items-center justify-between gap-3">
      <div><h3 className="flex items-center gap-2 text-lg font-black"><MapPin className="h-5 w-5 text-primary"/> الذروة حسب المدينة والحي</h3>
      <p className="mt-1 text-xs text-muted-foreground">كل إعداد مستقل حسب المحافظة والمنطقة والفئة، ويُحدد بنقطة GPS ونصف قطر.</p></div>
      <button onClick={()=>void load()} className="rounded-xl border px-3 py-2 text-xs font-bold"><RefreshCw className="ml-1 inline h-4 w-4"/> تحديث</button>
    </header>

    <div className="rounded-xl border border-border bg-muted/20 p-4 space-y-3">
      <div className="flex items-center justify-between"><b className="text-sm">{editingId?"تعديل إعداد منطقة":"إضافة منطقة ذروة"}</b>{editingId&&<button onClick={resetForm} className="text-xs font-bold text-muted-foreground">إلغاء التعديل</button>}</div>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <label className="space-y-1 text-xs font-bold">المحافظة<select value={governorate} onChange={e=>setGovernorate(e.target.value)} className="w-full rounded-lg border bg-background p-2.5">{GOVERNORATES.map(g=><option key={g.key} value={g.key}>{g.name}</option>)}</select></label>
        <label className="space-y-1 text-xs font-bold">المدينة أو القضاء<input value={city} onChange={e=>setCity(e.target.value)} placeholder="مثلاً: النجف" className="w-full rounded-lg border bg-background p-2.5"/></label>
        <label className="space-y-1 text-xs font-bold">الحي (اختياري)<input value={neighborhood} onChange={e=>setNeighborhood(e.target.value)} placeholder="مثلاً: حي الأنصار" className="w-full rounded-lg border bg-background p-2.5"/></label>
        <label className="space-y-1 text-xs font-bold">الفئة<select value={category} onChange={e=>setCategory(e.target.value)} className="w-full rounded-lg border bg-background p-2.5">{categories.map(x=><option key={x.value} value={x.value}>{x.label}</option>)}</select></label>
        <label className="space-y-1 text-xs font-bold">خط العرض GPS<input inputMode="decimal" value={lat} onChange={e=>setLat(e.target.value)} className="w-full rounded-lg border bg-background p-2.5"/></label>
        <label className="space-y-1 text-xs font-bold">خط الطول GPS<input inputMode="decimal" value={lng} onChange={e=>setLng(e.target.value)} className="w-full rounded-lg border bg-background p-2.5"/></label>
        <label className="space-y-1 text-xs font-bold">نصف قطر المنطقة (كم)<input type="number" min="0.1" max="40" step="0.1" value={radius} onChange={e=>setRadius(e.target.value)} className="w-full rounded-lg border bg-background p-2.5"/></label>
        <label className="space-y-1 text-xs font-bold">الزيادة من (%)<input type="number" min="0" max="100" value={minimum} onChange={e=>setMinimum(e.target.value)} className="w-full rounded-lg border bg-background p-2.5"/></label>
        <label className="space-y-1 text-xs font-bold">الزيادة إلى (%)<input type="number" min="0" max="100" value={maximum} onChange={e=>setMaximum(e.target.value)} className="w-full rounded-lg border bg-background p-2.5"/></label>
        <label className="space-y-1 text-xs font-bold">وضع التشغيل<select value={mode} onChange={e=>{const v=e.target.value as Mode;setMode(v);if(v==="off")setEnabled(false);}} className="w-full rounded-lg border bg-background p-2.5"><option value="off">إيقاف</option><option value="auto">تلقائي</option><option value="notify">إخباري</option></select></label>
        <label className="flex items-center gap-2 pt-5 text-xs font-bold"><input type="checkbox" checked={enabled} disabled={mode==="off"} onChange={e=>setEnabled(e.target.checked)}/> تفعيل هذه المنطقة والفئة</label>
      </div>
      <p className="text-[11px] leading-5 text-muted-foreground">حدد إحداثيات مركز الحي أو المدينة من الخريطة، ثم اختر نصف القطر. الحي الأصغر يتقدم على نطاق المدينة إذا تداخلت المناطق. الطقس المتاح حالياً على مستوى المحافظة، والطلب وGPS يُحسبان داخل نصف قطر المنطقة.</p>
      <div className="flex flex-wrap gap-2">
        <button disabled={saving} onClick={()=>void save()} className="rounded-xl bg-primary px-4 py-2.5 text-xs font-black text-primary-foreground disabled:opacity-50"><Save className="ml-1 inline h-4 w-4"/>{saving?"جارٍ الحفظ…":"حفظ إعداد المنطقة"}</button>
        <a href={`https://www.google.com/maps?q=${encodeURIComponent(lat+","+lng)}`} target="_blank" rel="noreferrer" className="rounded-xl border px-4 py-2.5 text-xs font-bold"><MapPin className="ml-1 inline h-4 w-4"/> فتح الإحداثيات بالخريطة</a>
      </div>
    </div>

    <div className="space-y-3">
      <h4 className="font-black">المناطق والفئات المحفوظة ({zones.length})</h4>
      {zones.length===0?<p className="rounded-xl bg-muted/30 p-4 text-xs text-muted-foreground">ماكو مناطق مضافة بعد. أضف مدينة أو حي وحدد مركزه ونصف قطره.</p>:zones.map(z=><article key={z.id} className="rounded-xl border border-border p-3 space-y-2">
        <div className="flex flex-wrap items-center justify-between gap-2"><b className="text-sm">{labels[z.governorate_key]||z.governorate_key} · {z.city_name}{z.neighborhood_name?" · "+z.neighborhood_name:""}</b><span className="rounded-full bg-muted px-2 py-1 text-[10px] font-bold">{categoryName(z.category_key,services)}</span></div>
        <div className="grid grid-cols-2 gap-2 text-xs sm:grid-cols-4"><span>الوضع: <b>{z.mode==="auto"?"تلقائي":z.mode==="notify"?"إخباري":"متوقف"}</b></span><span>الحالة: <b>{z.enabled?"مفعّل":"مطفأ"}</b></span><span>النطاق: <b>{z.radius_km} كم</b></span><span>الزيادة: <b>{z.min_surcharge_percent}–{z.max_surcharge_percent}%</b></span><span>المتواجدون: <b>{z.active_providers}/{z.observed_providers}</b></span><span>الطلبات: <b>{z.pending_requests}</b></span><span>المطبّق حالياً: <b>{z.active_percent}%</b></span><span>آخر فحص: <b>{z.last_calculated_at?new Date(z.last_calculated_at).toLocaleTimeString("ar-IQ"):"—"}</b></span></div>
        <p className="text-[11px] text-muted-foreground">{z.last_reason||"بانتظار أول دورة مراقبة."}</p>
        <div className="flex flex-wrap items-center gap-2"><button onClick={()=>editZone(z)} className="rounded-lg border px-3 py-2 text-xs font-bold">تعديل الإعداد</button><a target="_blank" rel="noreferrer" href={`https://www.google.com/maps?q=${z.center_lat},${z.center_lng}`} className="rounded-lg border px-3 py-2 text-xs font-bold">عرض الموقع</a></div>
      </article>)}
    </div>

    <div className="space-y-3">
      <h4 className="flex items-center gap-2 font-black"><BellRing className="h-4 w-4"/> توصيات تنتظر قرار الإدارة ({recommendations.length})</h4>
      {recommendations.length===0?<p className="rounded-xl bg-muted/30 p-4 text-xs text-muted-foreground">ماكو توصيات معلّقة حالياً. عند اختيار الوضع الإخباري سيظهر هنا أي ضغط يستدعي مراجعة الإدارة.</p>:recommendations.map(r=><article key={r.id} className="rounded-xl border border-amber-500/30 bg-amber-500/5 p-3 space-y-2">
        <b className="text-sm">{labels[r.governorate_key]||r.governorate_key} · {r.city_name}{r.neighborhood_name?" · "+r.neighborhood_name:""}</b>
        <div className="text-xs">الفئة: <b>{categoryName(r.category_key,services)}</b> · الزيادة المقترحة: <b>{r.suggested_percent}%</b></div>
        <div className="grid grid-cols-2 gap-2 text-xs sm:grid-cols-4"><span>المتاحون: {r.active_providers}</span><span>GPS المرصود: {r.observed_providers}</span><span>الطلبات: {r.pending_requests}</span><span>طلب/متاح: {r.demand_per_provider}</span></div>
        <p className="text-xs text-muted-foreground">{r.reason}</p>
        <p className="text-[10px] text-muted-foreground">الطقس: {String(r.weather?.condition_text||"غير متوفر")} · {r.weather?.temperature_c??"—"}° · مطر {r.weather?.rain_mm??"—"} ملم</p>
        <a target="_blank" rel="noreferrer" href={`https://www.google.com/maps?q=${r.center_lat},${r.center_lng}`} className="inline-block text-xs font-bold text-primary underline">فتح موقع التوصية بالخريطة</a>
        <div className="flex gap-2 pt-1"><button disabled={deciding===r.id} onClick={()=>void decide(r.id,true)} className="rounded-lg bg-emerald-600 px-4 py-2 text-xs font-black text-white disabled:opacity-50"><Check className="ml-1 inline h-4 w-4"/> موافقة لمدة 30 دقيقة</button><button disabled={deciding===r.id} onClick={()=>void decide(r.id,false)} className="rounded-lg border border-red-300 px-4 py-2 text-xs font-black text-red-600 disabled:opacity-50"><X className="ml-1 inline h-4 w-4"/> رفض</button></div>
      </article>)}
    </div>
  </section>;
}
