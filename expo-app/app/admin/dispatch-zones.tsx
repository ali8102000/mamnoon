import { useCallback, useEffect, useState } from "react";
import { ActivityIndicator, Alert, ScrollView, StyleSheet, Text, TextInput, TouchableOpacity, View } from "react-native";
import { Stack } from "expo-router";
import { supabase } from "@/lib/supabase";
import { palette, radius } from "@/styles/theme";
import { IRAQ_GOVERNORATES } from "@/lib/governorates";

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
  inherited?: boolean;
};
const TYPES: DispatchType[] = ["taxi", "large_driver", "technician"];
const LABELS: Record<DispatchType, string> = {
  taxi: "سائقو التكسي الاعتيادي",
  large_driver: "الكيات والباصات والسيارات الكبيرة",
  technician: "الفنيون ومقدمو الخدمات",
};
const DEFAULTS: Record<DispatchType, Omit<Row, "governorate_key" | "category_key">> = {
  taxi: { dispatch_type: "taxi", ring1_min_km: 0, ring1_max_km: 1, ring2_min_km: 1, ring2_max_km: 2, ring3_min_km: 2, ring3_max_km: 3, ring4_min_km: 3, ring4_max_km: 4, ring5_min_km: 4, ring5_max_km: 4.5, ring6_min_km: 4.5, ring6_max_km: 5, ring1_duration_seconds: 60, ring2_duration_seconds: 60, ring3_duration_seconds: 60, ring4_duration_seconds: 60, ring5_duration_seconds: 60, ring6_duration_seconds: 60 },
  large_driver: { dispatch_type: "large_driver", ring1_min_km: 0, ring1_max_km: 5, ring2_min_km: 5, ring2_max_km: 10, ring3_min_km: 10, ring3_max_km: 20, ring4_min_km: 20, ring4_max_km: 30, ring5_min_km: 30, ring5_max_km: 40, ring6_min_km: 40, ring6_max_km: 55, ring1_duration_seconds: 60, ring2_duration_seconds: 60, ring3_duration_seconds: 60, ring4_duration_seconds: 60, ring5_duration_seconds: 60, ring6_duration_seconds: 60 },
  technician: { dispatch_type: "technician", ring1_min_km: 0, ring1_max_km: 5, ring2_min_km: 5, ring2_max_km: 10, ring3_min_km: 10, ring3_max_km: 20, ring4_min_km: 20, ring4_max_km: 30, ring5_min_km: 30, ring5_max_km: 40, ring6_min_km: 40, ring6_max_km: 55, ring1_duration_seconds: 60, ring2_duration_seconds: 60, ring3_duration_seconds: 60, ring4_duration_seconds: 60, ring5_duration_seconds: 60, ring6_duration_seconds: 60 },
};

export default function AdminDispatchZonesScreen() {
  const [governorate, setGovernorate] = useState("all");
  const [categoryKey, setCategoryKey] = useState("all");
  const [services, setServices] = useState<ServiceOption[]>([]);
  const [rows, setRows] = useState<Row[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState<DispatchType | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    const [zoneResult, serviceResult] = await Promise.all([
      (supabase as any).rpc("admin_get_dispatch_zone_settings"),
      (supabase as any).from("services").select("slug,name_ar").order("sort_order"),
    ]);
    if (serviceResult.error) Alert.alert("تعذر تحميل فئات الخدمات", serviceResult.error.message);
    else setServices((serviceResult.data ?? []) as ServiceOption[]);
    if (zoneResult.error) {
      Alert.alert("تعذر تحميل نطاقات التوزيع", zoneResult.error.message);
      setRows([]);
    } else {
      const allRows = (zoneResult.data ?? []) as Row[];
      setRows(TYPES.map((type) => {
        const category = type === "technician" ? categoryKey : "all";
        const candidates = [
          allRows.find((item) => item.governorate_key === governorate && item.dispatch_type === type && item.category_key === category),
          allRows.find((item) => item.governorate_key === governorate && item.dispatch_type === type && item.category_key === "all"),
          allRows.find((item) => item.governorate_key === "all" && item.dispatch_type === type && item.category_key === category),
          allRows.find((item) => item.governorate_key === "all" && item.dispatch_type === type && item.category_key === "all"),
        ];
        const selected = candidates.find(Boolean);
        return {
          ...(selected ?? DEFAULTS[type]),
          governorate_key: governorate,
          category_key: category,
          inherited: !candidates[0],
        } as Row;
      }));
    }
    setLoading(false);
  }, [governorate, categoryKey]);

  useEffect(() => { void load(); }, [load]);

  const update = (type: DispatchType, key: "ring1_min_km" | "ring1_max_km" | "ring2_min_km" | "ring2_max_km" | "ring3_min_km" | "ring3_max_km" | "ring4_min_km" | "ring4_max_km" | "ring5_min_km" | "ring5_max_km" | "ring6_min_km" | "ring6_max_km" | "ring1_duration_seconds" | "ring2_duration_seconds" | "ring3_duration_seconds" | "ring4_duration_seconds" | "ring5_duration_seconds" | "ring6_duration_seconds", value: string) => {
    setRows((current) => current.map((row) =>
      row.dispatch_type === type ? { ...row, [key]: value === "" ? 0 : Number(value), inherited: false } : row
    ));
  };

  const save = async (row: Row) => {
    const mins = [row.ring1_min_km,row.ring2_min_km,row.ring3_min_km,row.ring4_min_km,row.ring5_min_km,row.ring6_min_km].map(Number);
    const maxs = [row.ring1_max_km,row.ring2_max_km,row.ring3_max_km,row.ring4_max_km,row.ring5_max_km,row.ring6_max_km].map(Number);
    const times = [row.ring1_duration_seconds,row.ring2_duration_seconds,row.ring3_duration_seconds,row.ring4_duration_seconds,row.ring5_duration_seconds,row.ring6_duration_seconds].map(Number);
    if (!(mins.every((v,i) => Number.isFinite(v) && v >= 0 && v < maxs[i]) && maxs.every((v) => Number.isFinite(v) && v <= 55) && times.every((v) => Number.isInteger(v) && v >= 5 && v <= 3600))) {
      Alert.alert("إعدادات غير صحيحة", "حدد بداية ونهاية صحيحتين لكل نطاق (من 0 إلى 55 كم)، واجعل النهاية أكبر من البداية، والمدة بين 5 و3600 ثانية.");
      return;
    }
    setSaving(row.dispatch_type);
    const { error } = await (supabase as any).rpc("admin_update_dispatch_zone_settings", {
      p_governorate_key: governorate,
      p_dispatch_type: row.dispatch_type,
      p_category_key: row.dispatch_type === "technician" ? categoryKey : "all",
      p_ring1_min_km: mins[0], p_ring1_max_km: maxs[0],
      p_ring2_min_km: mins[1], p_ring2_max_km: maxs[1],
      p_ring3_min_km: mins[2], p_ring3_max_km: maxs[2],
      p_ring4_min_km: mins[3], p_ring4_max_km: maxs[3],
      p_ring5_min_km: mins[4], p_ring5_max_km: maxs[4],
      p_ring6_min_km: mins[5], p_ring6_max_km: maxs[5],
      p_ring1_duration_seconds: times[0],
      p_ring2_duration_seconds: times[1],
      p_ring3_duration_seconds: times[2],
      p_ring4_duration_seconds: times[3],
      p_ring5_duration_seconds: times[4],
      p_ring6_duration_seconds: times[5],
    });
    setSaving(null);
    if (error) {
      Alert.alert("تعذر تأكيد النطاق", error.message);
    } else {
      Alert.alert("تم التأكيد والحفظ", "انحفظت مسافات ومدد النطاقات الستة لهذه الفئة والمحافظة. ينتقل الطلب تلقائياً بعد انتهاء مدة كل نطاق.");
      await load();
    }
  };

  return (
    <ScrollView style={styles.page} contentContainerStyle={styles.container}>
      <Stack.Screen options={{ title: "نطاقات توزيع الطلبات" }} />
      <Text style={styles.title}>التحكم بنطاقات توزيع الطلبات</Text>
      <Text style={styles.note}>حدد المحافظة وفئة الخدمة، ثم اختر مسافة بداية ونهاية مستقلة لكل نطاق ومدة كل مرحلة. تگدر تخلي النطاقات تصاعدية أو تعيد نفس المسافات أو ترتبها بالطريقة اللي تريدها؛ ماكو شرط للتصاعد.</Text>

      <View style={styles.card}>
        <Text style={styles.label}>المحافظة</Text>
        <View style={styles.chips}>
          <TouchableOpacity onPress={() => setGovernorate("all")} style={[styles.chip, governorate === "all" && styles.chipActive]}>
            <Text style={[styles.chipText, governorate === "all" && styles.chipTextActive]}>كل العراق</Text>
          </TouchableOpacity>
          {IRAQ_GOVERNORATES.map((item) => (
            <TouchableOpacity key={item.key} onPress={() => setGovernorate(item.key)} style={[styles.chip, governorate === item.key && styles.chipActive]}>
              <Text style={[styles.chipText, governorate === item.key && styles.chipTextActive]}>{item.name}</Text>
            </TouchableOpacity>
          ))}
        </View>
        <Text style={styles.label}>فئة الخدمة للفنيين</Text>
        <View style={styles.chips}>
          <TouchableOpacity onPress={() => setCategoryKey("all")} style={[styles.chip, categoryKey === "all" && styles.chipActive]}>
            <Text style={[styles.chipText, categoryKey === "all" && styles.chipTextActive]}>كل الخدمات</Text>
          </TouchableOpacity>
          {services.map((item) => (
            <TouchableOpacity key={item.slug} onPress={() => setCategoryKey(item.slug)} style={[styles.chip, categoryKey === item.slug && styles.chipActive]}>
              <Text style={[styles.chipText, categoryKey === item.slug && styles.chipTextActive]}>{item.name_ar}</Text>
            </TouchableOpacity>
          ))}
        </View>
        <Text style={styles.hint}>التكسي والسيارات الكبيرة لها إعداد مستقل. اختيار فئة الخدمة يخصص نطاق الفنيين لهذه الخدمة فقط.</Text>
      </View>

      {loading ? <ActivityIndicator color={palette.brand} /> : rows.map((row) => (
        <View key={row.dispatch_type} style={styles.card}>
          <View style={styles.headingRow}>
            <Text style={styles.cardTitle}>{LABELS[row.dispatch_type]}</Text>
            {row.inherited && <Text style={styles.inherited}>يرث الإعداد الأقرب</Text>}
          </View>
          {([1,2,3,4,5,6] as const).map((index) => (
            <View key={index} style={styles.rangeBox}>
              <Text style={styles.label}>النطاق {index}{index === 6 ? " — المرحلة الأخيرة" : ""}</Text>
              <Text style={styles.label}>من (كم)</Text>
              <TextInput value={String(row[("ring" + index + "_min_km") as keyof Row])} onChangeText={(value) => update(row.dispatch_type, ("ring" + index + "_min_km") as any, value)} keyboardType="decimal-pad" style={styles.input} />
              <Text style={styles.label}>إلى (كم)</Text>
              <TextInput value={String(row[("ring" + index + "_max_km") as keyof Row])} onChangeText={(value) => update(row.dispatch_type, ("ring" + index + "_max_km") as any, value)} keyboardType="decimal-pad" style={styles.input} />
              <Text style={styles.hint}>هذا النطاق مستقل؛ تگدر تكرر مسافة نطاق سابق أو تختار مسافة مختلفة.</Text>
            </View>
          ))}
          {([
            { key: "ring1_duration_seconds", label: "مدة النطاق الأول" },
            { key: "ring2_duration_seconds", label: "مدة النطاق الثاني" },
            { key: "ring3_duration_seconds", label: "مدة النطاق الثالث" },
            { key: "ring4_duration_seconds", label: "مدة النطاق الرابع" },
            { key: "ring5_duration_seconds", label: "مدة النطاق الخامس" },
            { key: "ring6_duration_seconds", label: "مدة النطاق السادس" },
          ] as const).map((field) => (
            <View key={field.key}>
              <Text style={styles.label}>{field.label} (ثانية)</Text>
              <TextInput
                value={String(row[field.key])}
                onChangeText={(value) => update(row.dispatch_type, field.key, value)}
                keyboardType="number-pad"
                style={styles.input}
              />
              <Text style={styles.hint}>المدة الفعلية قبل انتقال الطلب إلى النطاق التالي — من 5 إلى 3600 ثانية</Text>
            </View>
          ))}
          <TouchableOpacity
            disabled={saving === row.dispatch_type}
            onPress={() => void save(row)}
            style={[styles.saveButton, saving === row.dispatch_type && styles.disabled]}
          >
            <Text style={styles.saveText}>{saving === row.dispatch_type ? "جارٍ التأكيد والحفظ..." : "تأكيد وحفظ النطاقات الستة"}</Text>
          </TouchableOpacity>
        </View>
      ))}
      <Text style={styles.note}>المراحل الست تُقرأ من إعدادات Supabase. عند انتهاء مدة أي نطاق ينتقل محرك التوزيع تلقائياً للنطاق التالي خلال دورة الفحص التالية (كل ثانية). تبقى حدود أهلية مقدم الخدمة واشتراكه مطبقة أيضاً.</Text>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  page: { flex: 1, backgroundColor: palette.pageCanvas },
  container: { padding: 16, paddingTop: 28, paddingBottom: 48, gap: 12 },
  title: { fontSize: 21, fontWeight: "900", color: palette.ink, textAlign: "right" },
  note: { fontSize: 11, lineHeight: 19, color: palette.muted, textAlign: "right" },
  card: { backgroundColor: palette.surface, borderColor: palette.line, borderWidth: 1, borderRadius: radius.lg, padding: 14, gap: 10 },
  rangeBox: { borderWidth: 1, borderColor: palette.line, borderRadius: radius.md, padding: 10, gap: 6 },
  headingRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", gap: 8 },
  cardTitle: { fontSize: 14, fontWeight: "900", color: palette.ink, textAlign: "right", flex: 1 },
  label: { fontSize: 11, fontWeight: "800", color: palette.ink, textAlign: "right" },
  chips: { flexDirection: "row", flexWrap: "wrap", gap: 6 },
  chip: { borderWidth: 1, borderColor: palette.line, backgroundColor: palette.pageCanvas, borderRadius: 18, paddingHorizontal: 10, paddingVertical: 8 },
  chipActive: { backgroundColor: palette.brand, borderColor: palette.brand },
  chipText: { color: palette.ink, fontSize: 10, fontWeight: "800" },
  chipTextActive: { color: palette.white },
  inherited: { color: palette.muted, fontSize: 9, fontWeight: "700" },
  input: { minHeight: 44, borderWidth: 1, borderColor: palette.line, borderRadius: radius.md, paddingHorizontal: 12, color: palette.ink, backgroundColor: palette.pageCanvas, textAlign: "right" },
  hint: { fontSize: 10, lineHeight: 16, color: palette.muted, textAlign: "right" },
  saveButton: { backgroundColor: palette.brand, borderRadius: radius.md, padding: 13, alignItems: "center" },
  saveText: { color: palette.white, fontSize: 12, fontWeight: "900" },
  disabled: { opacity: 0.55 },
});
