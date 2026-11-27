import { useCallback, useEffect, useState } from "react";
import { ActivityIndicator, Alert, ScrollView, StyleSheet, Text, TextInput, TouchableOpacity, View } from "react-native";
import { Stack } from "expo-router";
import { supabase } from "@/lib/supabase";
import { useAuth } from "@/lib/auth-context";
import { palette, radius, space } from "@/styles/theme";
import { IRAQ_GOVERNORATES } from "@/lib/governorates";

type Mode="auto"|"notify"|"off";
type Zone={id:string;governorate_key:string;city_name:string;neighborhood_name:string;category_key:string;center_lat:number;center_lng:number;radius_km:number;min_surcharge_percent:number;max_surcharge_percent:number;mode:Mode;enabled:boolean;active_percent:number;observed_providers:number;active_providers:number;pending_requests:number;last_reason:string|null};
type Recommendation={id:string;governorate_key:string;city_name:string;neighborhood_name:string;category_key:string;suggested_percent:number;active_providers:number;observed_providers:number;pending_requests:number;demand_per_provider:number;reason:string;center_lat:number;center_lng:number};
const TAXI=[["taxi:economy","تكسي اقتصادي"],["taxi:premium","تكسي متميز"],["taxi:luxury","تكسي فاخر"],["taxi:large","سيارات كبيرة"]] as const;
const govName=(key:string)=>IRAQ_GOVERNORATES.find(g=>g.key===key)?.name||key;

export default function AdminPeakPricingScreen(){
 const {user,loading:authLoading}=useAuth();
 const [allowed,setAllowed]=useState<boolean|null>(null);const [loading,setLoading]=useState(true);const [saving,setSaving]=useState(false);const [deciding,setDeciding]=useState<string|null>(null);
 const [zones,setZones]=useState<Zone[]>([]);const [recommendations,setRecommendations]=useState<Recommendation[]>([]);const [services,setServices]=useState<any[]>([]);
 const [governorate,setGovernorate]=useState("najaf");const [city,setCity]=useState("");const [neighborhood,setNeighborhood]=useState("");const [category,setCategory]=useState("taxi:economy");
 const [lat,setLat]=useState("32.0259");const [lng,setLng]=useState("44.3462");const [radiusKm,setRadiusKm]=useState("3");const [minimum,setMinimum]=useState("5");const [maximum,setMaximum]=useState("20");const [mode,setMode]=useState<Mode>("off");const [enabled,setEnabled]=useState(false);const [editingId,setEditingId]=useState<string|null>(null);
 const load=useCallback(async()=>{
  if(!user?.id)return;setLoading(true);
  const [perm,z,r,s]=await Promise.all([
   (supabase as any).rpc("admin_has_any_pricing_permission"),
   (supabase as any).from("regional_peak_pricing_settings").select("*").order("governorate_key").order("city_name"),
   (supabase as any).from("regional_peak_recommendations").select("*").eq("status","pending").order("created_at",{ascending:false}).limit(30),
   (supabase as any).from("services").select("slug,name_ar").order("sort_order")
  ]);
  setAllowed(!perm.error&&perm.data===true);if(z.error)Alert.alert("خطأ","تعذر تحميل المناطق: "+z.error.message);if(r.error)Alert.alert("خطأ","تعذر تحميل التوصيات: "+r.error.message);
  setZones(z.data??[]);setRecommendations(r.data??[]);setServices(s.data??[]);setLoading(false);
 },[user?.id]);
 useEffect(()=>{if(!authLoading&&user?.id)void load();else if(!authLoading){setAllowed(false);setLoading(false);}},[authLoading,user?.id,load]);
 const categoryLabel=(key:string)=>TAXI.find(x=>x[0]===key)?.[1]||services.find(s=>"service:"+s.slug===key)?.name_ar||key;
 const reset=()=>{setEditingId(null);setCity("");setNeighborhood("");setCategory("taxi:economy");const g=IRAQ_GOVERNORATES.find(x=>x.key===governorate)||IRAQ_GOVERNORATES[0];setLat(String(g.latitude));setLng(String(g.longitude));setRadiusKm("3");setMinimum("5");setMaximum("20");setMode("off");setEnabled(false);};
 const edit=(z:Zone)=>{setEditingId(z.id);setGovernorate(z.governorate_key);setCity(z.city_name);setNeighborhood(z.neighborhood_name);setCategory(z.category_key);setLat(String(z.center_lat));setLng(String(z.center_lng));setRadiusKm(String(z.radius_km));setMinimum(String(z.min_surcharge_percent));setMaximum(String(z.max_surcharge_percent));setMode(z.mode);setEnabled(z.enabled);};
 const save=async()=>{
  const a=Number(lat),b=Number(lng),r=Number(radiusKm),lo=Number(minimum),hi=Number(maximum);
  if(!city.trim()||!Number.isFinite(a)||!Number.isFinite(b)||a<29||a>38||b<38||b>49||r<0.1||r>40||lo<0||hi>100||lo>hi){Alert.alert("تحقق من البيانات","راجع اسم المدينة والإحداثيات ونصف القطر والنسب.");return;}
  if(mode==="off"&&enabled){Alert.alert("تنبيه","لا يمكن تفعيل إعداد وضعه إيقاف.");return;}
  setSaving(true);const {error}=await (supabase as any).rpc("admin_save_regional_peak_pricing",{p_governorate_key:governorate,p_city_name:city.trim(),p_neighborhood_name:neighborhood.trim(),p_category_key:category,p_center_lat:a,p_center_lng:b,p_radius_km:r,p_min_surcharge_percent:lo,p_max_surcharge_percent:hi,p_mode:mode,p_enabled:enabled});setSaving(false);
  if(error)Alert.alert("تعذر الحفظ",error.message);else{Alert.alert("تم الحفظ","انحفظ إعداد المنطقة والفئة.");reset();await load();}
 };
 const decide=async(id:string,approve:boolean)=>{setDeciding(id);const {error}=await (supabase as any).rpc("admin_decide_regional_peak_recommendation",{p_recommendation_id:id,p_approve:approve});setDeciding(null);if(error)Alert.alert("تعذر القرار",error.message);else{Alert.alert("تم",approve?"تمت الموافقة لمدة 30 دقيقة.":"تم رفض التوصية.");await load();}};
 if(authLoading||loading||allowed===null)return <View style={s.center}><ActivityIndicator color={palette.brand}/><Text style={s.muted}>جارٍ تحميل إعدادات الذروة…</Text></View>;
 if(!allowed)return <View style={s.center}><Text style={s.title}>غير مصرّح</Text><Text style={s.muted}>تحتاج صلاحية إدارة الذروة.</Text></View>;
 return <View style={s.page}><Stack.Screen options={{title:"الذروة حسب المناطق"}}/><ScrollView contentContainerStyle={s.content} keyboardShouldPersistTaps="handled">
  <Text style={s.title}>التسعير حسب المدينة والحي</Text><Text style={s.muted}>حدد مركز المنطقة بإحداثيات GPS ونصف قطر. إعداد كل فئة مستقل، والافتراضي متوقف.</Text>
  <View style={s.card}><Text style={s.cardTitle}>{editingId?"تعديل منطقة":"إضافة منطقة جديدة"}</Text>
   <Text style={s.label}>المحافظة</Text><View style={s.choices}>{IRAQ_GOVERNORATES.map(g=><TouchableOpacity key={g.key} onPress={()=>{setGovernorate(g.key);setLat(String(g.latitude));setLng(String(g.longitude));}} style={[s.choice,governorate===g.key&&s.selected]}><Text style={[s.choiceText,governorate===g.key&&s.selectedText]}>{g.name}</Text></TouchableOpacity>)}</View>
   <Text style={s.label}>المدينة أو القضاء</Text><TextInput value={city} onChangeText={setCity} placeholder="مثلاً: النجف" placeholderTextColor={palette.muted} style={s.input}/>
   <Text style={s.label}>الحي (اختياري)</Text><TextInput value={neighborhood} onChangeText={setNeighborhood} placeholder="مثلاً: حي الأنصار" placeholderTextColor={palette.muted} style={s.input}/>
   <Text style={s.label}>الفئة</Text><View style={s.choices}>{[...TAXI.map(x=>({value:x[0],label:x[1]})),...services.map(x=>({value:"service:"+x.slug,label:x.name_ar}))].map(x=><TouchableOpacity key={x.value} onPress={()=>setCategory(x.value)} style={[s.choice,category===x.value&&s.selected]}><Text style={[s.choiceText,category===x.value&&s.selectedText]}>{x.label}</Text></TouchableOpacity>)}</View>
   <View style={s.row}><View style={{flex:1}}><Text style={s.label}>خط العرض</Text><TextInput value={lat} onChangeText={setLat} keyboardType="decimal-pad" style={s.input}/></View><View style={{flex:1}}><Text style={s.label}>خط الطول</Text><TextInput value={lng} onChangeText={setLng} keyboardType="decimal-pad" style={s.input}/></View></View>
   <View style={s.row}><View style={{flex:1}}><Text style={s.label}>نصف القطر كم</Text><TextInput value={radiusKm} onChangeText={setRadiusKm} keyboardType="decimal-pad" style={s.input}/></View><View style={{flex:1}}><Text style={s.label}>من نسبة %</Text><TextInput value={minimum} onChangeText={setMinimum} keyboardType="decimal-pad" style={s.input}/></View><View style={{flex:1}}><Text style={s.label}>إلى نسبة %</Text><TextInput value={maximum} onChangeText={setMaximum} keyboardType="decimal-pad" style={s.input}/></View></View>
   <Text style={s.label}>وضع التشغيل</Text><View style={s.choices}>{([{v:"off",l:"إيقاف"},{v:"auto",l:"تلقائي"},{v:"notify",l:"إخباري"}] as const).map(x=><TouchableOpacity key={x.v} onPress={()=>{setMode(x.v);if(x.v==="off")setEnabled(false);}} style={[s.choice,mode===x.v&&s.selected]}><Text style={[s.choiceText,mode===x.v&&s.selectedText]}>{x.l}</Text></TouchableOpacity>)}</View>
   <TouchableOpacity disabled={mode==="off"} onPress={()=>setEnabled(v=>!v)} style={s.toggle}><Text style={s.choiceText}>{enabled?"● مفعّل":"○ غير مفعّل"}</Text></TouchableOpacity>
   <Text style={s.muted}>مركز المنطقة: استخدم إحداثيات المكان من الخريطة. الحي ذو نصف القطر الأصغر له الأولوية. الطقس يُقرأ على مستوى المحافظة حالياً، والطلب وGPS يُحسبان داخل النطاق المحدد.</Text>
   <TouchableOpacity disabled={saving} onPress={()=>void save()} style={s.primary}><Text style={s.primaryText}>{saving?"جارٍ الحفظ…":"حفظ إعداد المنطقة"}</Text></TouchableOpacity>{editingId&&<TouchableOpacity onPress={reset} style={s.secondary}><Text style={s.choiceText}>إلغاء التعديل</Text></TouchableOpacity>}
  </View>
  <Text style={s.cardTitle}>المناطق المحفوظة ({zones.length})</Text>
  {zones.map(z=><View key={z.id} style={s.card}><Text style={s.cardTitle}>{govName(z.governorate_key)} · {z.city_name}{z.neighborhood_name?" · "+z.neighborhood_name:""}</Text><Text style={s.muted}>{categoryLabel(z.category_key)} · {z.mode==="auto"?"تلقائي":z.mode==="notify"?"إخباري":"متوقف"} · {z.enabled?"مفعّل":"مطفأ"}</Text><Text style={s.muted}>الزيادة {z.min_surcharge_percent}–{z.max_surcharge_percent}% · المطبّق {z.active_percent}% · المتاح {z.active_providers}/{z.observed_providers} · الطلبات {z.pending_requests}</Text><Text style={s.muted}>{z.last_reason||"بانتظار المراقبة"}</Text><TouchableOpacity onPress={()=>edit(z)} style={s.secondary}><Text style={s.choiceText}>تعديل</Text></TouchableOpacity></View>)}
  <Text style={s.cardTitle}>توصيات تنتظر قرارك ({recommendations.length})</Text>
  {recommendations.map(r=><View key={r.id} style={s.card}><Text style={s.cardTitle}>{govName(r.governorate_key)} · {r.city_name}{r.neighborhood_name?" · "+r.neighborhood_name:""}</Text><Text style={s.muted}>{categoryLabel(r.category_key)} · مقترح {r.suggested_percent}%</Text><Text style={s.muted}>المتاح {r.active_providers} · GPS {r.observed_providers} · الطلبات {r.pending_requests} · نسبة الضغط {r.demand_per_provider}</Text><Text style={s.muted}>{r.reason}</Text><View style={s.row}><TouchableOpacity disabled={deciding===r.id} onPress={()=>void decide(r.id,true)} style={[s.primary,{flex:1}]}><Text style={s.primaryText}>موافقة 30 دقيقة</Text></TouchableOpacity><TouchableOpacity disabled={deciding===r.id} onPress={()=>void decide(r.id,false)} style={[s.secondary,{flex:1}]}><Text style={s.choiceText}>رفض</Text></TouchableOpacity></View></View>)}
  <TouchableOpacity onPress={()=>void load()} style={s.secondary}><Text style={s.choiceText}>تحديث البيانات</Text></TouchableOpacity>
 </ScrollView></View>;
}
const s=StyleSheet.create({
 page:{flex:1,backgroundColor:palette.pageCanvas},content:{padding:space.lg,gap:12,paddingBottom:50},center:{flex:1,alignItems:"center",justifyContent:"center",backgroundColor:palette.pageCanvas,gap:10},title:{fontSize:21,fontWeight:"900",color:palette.ink,textAlign:"right"},muted:{fontSize:11,color:palette.muted,textAlign:"right",lineHeight:19},card:{backgroundColor:palette.surface,borderWidth:1,borderColor:palette.line,borderRadius:radius.lg,padding:13,gap:8},cardTitle:{fontSize:14,fontWeight:"900",color:palette.ink,textAlign:"right"},label:{fontSize:12,fontWeight:"800",color:palette.ink,textAlign:"right",marginTop:4},input:{backgroundColor:palette.canvas,borderWidth:1,borderColor:palette.line,borderRadius:radius.md,padding:11,color:palette.ink,textAlign:"right"},row:{flexDirection:"row",gap:8},choices:{flexDirection:"row",flexWrap:"wrap",gap:6},choice:{paddingHorizontal:10,paddingVertical:9,borderWidth:1,borderColor:palette.line,borderRadius:radius.md,backgroundColor:palette.canvas},selected:{backgroundColor:palette.brand,borderColor:palette.brand},choiceText:{fontSize:11,fontWeight:"800",color:palette.ink},selectedText:{color:palette.white},toggle:{padding:10,borderWidth:1,borderColor:palette.line,borderRadius:radius.md,alignItems:"center"},primary:{backgroundColor:palette.brand,padding:12,borderRadius:radius.md,alignItems:"center",justifyContent:"center"},primaryText:{color:palette.white,fontSize:12,fontWeight:"900"},secondary:{borderWidth:1,borderColor:palette.line,padding:10,borderRadius:radius.md,alignItems:"center"}
});
