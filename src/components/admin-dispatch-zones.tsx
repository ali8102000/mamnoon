import { useCallback, useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { GOVERNORATES } from "@/lib/governorates";
import { toast } from "@/lib/toast";

type DispatchType = "taxi" | "large_driver" | "technician";
type ServiceOption = { slug: string; name_ar: string };
type Row = {
  governorate_key: string;
  dispatch_type: DispatchType;
  category_key: string;
  ring1_min_km: number;
  ring1_max_km: number;
  ring2_min_km: number;
  ring2_max_km: number;
  ring3_min_km: number;
  ring3_max_km: number;
  ring4_min_km: number;
  ring4_max_km: number;
  ring5_min_km: number;
  ring5_max_km: number;
  ring6_min_km: number;
  ring6_max_km: number;
  ring1_duration_seconds: number;
  ring2_duration_seconds: number;
  ring3_duration_seconds: number;
  ring4_duration_seconds: number;
  ring5_duration_seconds: number;
  ring6_duration_seconds: number;
  updated_at?: string;
  inherited?: boolean;
};

const TYPES: DispatchType[] = ["taxi", "large_driver", "technician"];
const LABELS: Record<DispatchType, string> = {
  taxi: "سائقو التكسي الاعتيادي",
  large_driver: "الكيات والباصات والسيارات الكبيرة",
  technician: "الفنيون ومقدمو الخدمات",
};
const DEFAULTS: Omit<Row, "governorate_key" | "category_key">[] = [
  { dispatch_type: "taxi", ring1_min_km: 0, ring1_max_km: 1, ring2_min_km: 1, ring2_max_km: 2, ring3_min_km: 2, ring3_max_km: 3, ring4_min_km: 3, ring4_max_km: 4, ring5_min_km: 4, ring5_max_km: 4.5, ring6_min_km: 4.5, ring6_max_km: 5, ring1_duration_seconds: 60, ring2_duration_seconds: 60, ring3_duration_seconds: 60, ring4_duration_seconds: 60, ring5_duration_seconds: 60, ring6_duration_seconds: 60 },
  { dispatch_type: "large_driver", ring1_min_km: 0, ring1_max_km: 5, ring2_min_km: 5, ring2_max_km: 10, ring3_min_km: 10, ring3_max_km: 20, ring4_min_km: 20, ring4_max_km: 30, ring5_min_km: 30, ring5_max_km: 40, ring6_min_km: 40, ring6_max_km: 55, ring1_duration_seconds: 60, ring2_duration_seconds: 60, ring3_duration_seconds: 60, ring4_duration_seconds: 60, ring5_duration_seconds: 60, ring6_duration_seconds: 60 },
  { dispatch_type: "technician", ring1_min_km: 0, ring1_max_km: 5, ring2_min_km: 5, ring2_max_km: 10, ring3_min_km: 10, ring3_max_km: 20, ring4_min_km: 20, ring4_max_km: 30, ring5_min_km: 30, ring5_max_km: 40, ring6_min_km: 40, ring6_max_km: 55, ring1_duration_seconds: 60, ring2_duration_seconds: 60, ring3_duration_seconds: 60, ring4_duration_seconds: 60, ring5_duration_seconds: 60, ring6_duration_seconds: 60 },
];

export default function AdminDispatchZones() {
  const [governorate, setGovernorate] = useState("all");
  const [categoryKey, setCategoryKey] = useState("all");
  const [services, setServices] = useState<ServiceOption[]>([]);
  const [rows, setRows] = useState<Row[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState<DispatchType | null>(null);

  useEffect(() => {
    let alive = true;
    void (async () => {
      const { data, error } = await (supabase as any).from("services").select("slug,name_ar").order("sort_order");
      if (!alive) return;
      if (error) toast.error("تعذر تحميل فئات الخدمات: " + error.message);
      else setServices((data ?? []) as ServiceOption[]);
    })();
    return () => { alive = false; };
  }, []);

  const load = useCallback(async () => {
    setLoading(true);
    const { data, error } = await (supabase as any).rpc("admin_get_dispatch_zone_settings");
    if (error) {
      toast.error("تعذر تحميل نطاقات التوزيع: " + error.message);
      setRows([]);
    } else {
      const allRows = (data ?? []) as Row[];
      const selectedRows = TYPES.map((type) => {
        const category = type === "technician" ? categoryKey : "all";
        const candidates = [
          allRows.find((r) => r.governorate_key === governorate && r.dispatch_type === type && r.category_key === category),
          allRows.find((r) => r.governorate_key === governorate && r.dispatch_type === type && r.category_key === "all"),
          allRows.find((r) => r.governorate_key === "all" && r.dispatch_type === type && r.category_key === category),
          allRows.find((r) => r.governorate_key === "all" && r.dispatch_type === type && r.category_key === "all"),
        ];
        const selected = candidates.find(Boolean);
        const defaults = DEFAULTS.find((r) => r.dispatch_type === type)!;
        return {
          ...(selected ?? defaults),
          governorate_key: governorate,
          category_key: category,
          inherited: !candidates[0],
        } as Row;
      });
      setRows(selectedRows);
    }
    setLoading(false);
  }, [governorate, categoryKey]);

  useEffect(() => { void load(); }, [load]);

  useEffect(() => {
    const channel = supabase
      .channel("admin-regional-dispatch-settings")
      .on("postgres_changes", { event: "*", schema: "public", table: "regional_dispatch_zone_settings" }, () => { void load(); })
      .subscribe();
    return () => { void supabase.removeChannel(channel); };
  }, [load]);

  const update = (type: DispatchType, key: "ring1_max_km" | "ring2_max_km" | "ring3_max_km" | "ring4_max_km" | "ring5_max_km" | "ring6_max_km" | "ring1_duration_seconds" | "ring2_duration_seconds" | "ring3_duration_seconds" | "ring4_duration_seconds" | "ring5_duration_seconds" | "ring6_duration_seconds", value: string) => {
    setRows((old) => old.map((r) => r.dispatch_type === type ? { ...r, [key]: value === "" ? 0 : Number(value), inherited: false } : r));
  };

  const save = async (row: Row) => {
    const a = Number(row.ring1_max_km);
    const b = Number(row.ring2_max_km);
    const c = Number(row.ring3_max_km);
    const d = Number(row.ring4_max_km);
    const e = Number(row.ring5_max_km);
    const f = Number(row.ring6_max_km);
    const times = [row.ring1_duration_seconds,row.ring2_duration_seconds,row.ring3_duration_seconds,row.ring4_duration_seconds,row.ring5_duration_seconds,row.ring6_duration_seconds].map(Number);
    if (!(a > 0 && b > a && c > b && d > c && e > d && f > e && f <= 55 && times.every((v) => Number.isInteger(v) && v >= 5 && v <= 3600))) {
      toast.error("رتّب مسافات النطاقات الستة تصاعدياً، وحدد مدة كل نطاق بين 5 و3600 ثانية");
      return;
    }
    setSaving(row.dispatch_type);
    const { error } = await (supabase as any).rpc("admin_update_dispatch_zone_settings", {
      p_governorate_key: governorate,
      p_dispatch_type: row.dispatch_type,
      p_category_key: row.category_key,
      p_ring1_max_km: a,
      p_ring2_max_km: b,
      p_ring3_max_km: c,
      p_ring4_max_km: d,
      p_ring5_max_km: e,
      p_ring6_max_km: f,
      p_ring1_duration_seconds: times[0],
      p_ring2_duration_seconds: times[1],
      p_ring3_duration_seconds: times[2],
      p_ring4_duration_seconds: times[3],
      p_ring5_duration_seconds: times[4],
      p_ring6_duration_seconds: times[5],
    });
    setSaving(null);
    if (error) toast.error(error.message);
    else {
      toast.success("تم حفظ النطاق. سيُقرأ مباشرة من Supabase في مرحلة التوزيع القادمة.");
      await load();
    }
  };

  const governorateName = governorate === "all" ? "كل العراق" : GOVERNORATES.find((g) => g.key === governorate)?.name ?? governorate;
  const categoryName = categoryKey === "all" ? "كل فئات الخدمات" : services.find((s) => s.slug === categoryKey)?.name_ar ?? categoryKey;

  return (
    <div className="space-y-4" dir="rtl">
      <div className="rounded-2xl border bg-card p-4">
        <h2 className="text-xl font-black">التحكم بنطاقات توزيع الطلبات</h2>
        <p className="mt-2 text-sm leading-6 text-muted-foreground">
          كل طلب يمر بستة نطاقات مختلفة، ولكل نطاق مسافة ومدة مستقلة. ينتقل النظام تلقائياً للنطاق التالي فور انتهاء المدة، مع فحص كل ثانية. مثال: 3 ثم 5 ثم 10 كم تعني الإرسال الأول من 0 إلى 3، والثاني من أكثر من 3 إلى 5، والثالث من أكثر من 5 إلى 10 كم. لا ينتقل الطلب خارج الحد الذي تحدده الإدارة.
        </p>
      </div>

      <div className="rounded-2xl border bg-card p-4 space-y-3">
        <div>
          <label className="block text-sm font-bold">المحافظة</label>
          <select value={governorate} onChange={(e) => setGovernorate(e.target.value)} className="mt-1 w-full rounded-xl border bg-background p-3">
            <option value="all">كل العراق — الإعداد العام</option>
            {GOVERNORATES.map((g) => <option key={g.key} value={g.key}>{g.name}</option>)}
          </select>
        </div>
        <div>
          <label className="block text-sm font-bold">فئة الخدمة للفنيين</label>
          <select value={categoryKey} onChange={(e) => setCategoryKey(e.target.value)} className="mt-1 w-full rounded-xl border bg-background p-3">
            <option value="all">كل فئات الخدمات</option>
            {services.map((service) => <option key={service.slug} value={service.slug}>{service.name_ar}</option>)}
          </select>
        </div>
        <p className="text-xs text-muted-foreground">
          الإعداد الحالي: {governorateName} — {categoryName}. الفئة المحددة تطبّق على الفنيين فقط؛ التكسي والسيارات الكبيرة لها إعداد مستقل. إذا لم يوجد تخصيص للمحافظة أو الفئة، يرث النظام الإعداد العام تلقائياً.
        </p>
      </div>

      {loading ? <div className="text-sm text-muted-foreground">جارٍ تحميل إعدادات Supabase...</div> : rows.map((row) => (
        <div key={row.dispatch_type} className="rounded-2xl border bg-card p-4 space-y-3">
          <div className="flex items-center justify-between gap-2">
            <h3 className="font-black">{LABELS[row.dispatch_type]}</h3>
            {row.inherited && <span className="rounded-full bg-muted px-2 py-1 text-[10px]">يرث الإعداد الأقرب</span>}
          </div>
          {([
            { key: "ring1_max_km", label: "الإرسال الأول — الأقرب" },
            { key: "ring2_max_km", label: "الإرسال الثاني" },
            { key: "ring3_max_km", label: "الإرسال الثالث" },
            { key: "ring4_max_km", label: "الإرسال الرابع" },
            { key: "ring5_max_km", label: "الإرسال الخامس" },
            { key: "ring6_max_km", label: "الإرسال السادس — الأبعد" },
          ] as const).map((field, i) => (
            <label key={field.key} className="block text-sm font-semibold">
              {field.label}
              <div className="mt-1 flex items-center gap-2">
                <input type="number" min={0.5} max={55} step="0.5" value={row[field.key]} onChange={(e) => update(row.dispatch_type, field.key, e.target.value)} className="w-full rounded-xl border bg-background p-3" />
                <span className="text-xs text-muted-foreground">كم</span>
              </div>
              <span className="text-[11px] text-muted-foreground">
                {i === 0 ? "من موقع الزبون إلى هذا الحد" : "من بعد " + (i === 1 ? row.ring1_max_km : i === 2 ? row.ring2_max_km : i === 3 ? row.ring3_max_km : i === 4 ? row.ring4_max_km : row.ring5_max_km) + " إلى هذا الحد"} كم
              </span>
            </label>
          ))}
          {([
            { key: "ring1_duration_seconds", label: "مدة النطاق الأول" },
            { key: "ring2_duration_seconds", label: "مدة النطاق الثاني" },
            { key: "ring3_duration_seconds", label: "مدة النطاق الثالث" },
            { key: "ring4_duration_seconds", label: "مدة النطاق الرابع" },
            { key: "ring5_duration_seconds", label: "مدة النطاق الخامس" },
            { key: "ring6_duration_seconds", label: "مدة النطاق السادس" },
          ] as const).map((field) => (
            <label key={field.key} className="block text-sm font-semibold">
              {field.label}
              <div className="mt-1 flex items-center gap-2">
                <input type="number" min={5} max={3600} step={1} value={row[field.key]} onChange={(e) => update(row.dispatch_type, field.key, e.target.value)} className="w-full rounded-xl border bg-background p-3" />
                <span className="text-xs text-muted-foreground">ثانية</span>
              </div>
              <span className="text-[11px] text-muted-foreground">مدة مستقلة؛ ينتقل تلقائياً للنطاق التالي عند انتهائها</span>
            </label>
          ))}
          <button disabled={saving === row.dispatch_type} onClick={() => void save(row)} className="w-full rounded-xl bg-primary py-3 font-bold text-primary-foreground disabled:opacity-50">
            {saving === row.dispatch_type ? "جارٍ الحفظ..." : "حفظ النطاقات الستة لهذه الفئة"}
          </button>
        </div>
      ))}

      <p className="text-xs text-muted-foreground">
        التغييرات محفوظة في Supabase. محرك التوزيع يقرأ الإعداد حسب المحافظة ونوع الطلب وفئة الخدمة عند كل مرحلة، مع بقاء نطاق اشتراك ومجال عمل مقدم الخدمة كحد إضافي لا يمكن تجاوزه. الحد الأعلى الحالي 55 كم.
      </p>
    </div>
  );
}
