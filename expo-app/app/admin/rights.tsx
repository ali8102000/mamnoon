import { useCallback, useEffect, useState } from "react";
import { ActivityIndicator, Alert, RefreshControl, ScrollView, StyleSheet, Text, TextInput, TouchableOpacity, View } from "react-native";
import { Stack } from "expo-router";
import { supabase } from "@/lib/supabase";
import { useAuth } from "@/lib/auth-context";
import { palette, radius, space } from "@/styles/theme";

type UserRow={id:string;full_name:string|null;phone:string|null;email:string|null;governorate_key:string|null;roles:string[];balance_iqd:number;partner?:any};
type Tab="wallet"|"special"|"policies"|"revenue";
const durations=[{value:"1",label:"يوم"},{value:"7",label:"أسبوع"},{value:"30",label:"شهر"},{value:"90",label:"٣ أشهر"},{value:"180",label:"٦ أشهر"},{value:"365",label:"سنة"},{value:"permanent",label:"دائم"}];
const COMMISSION_CATEGORIES=[
 {role:"driver",label:"التكسي الاعتيادي",event:"taxi_acceptance"},
 {role:"large_driver",label:"الكيات والسيارات الكبيرة",event:"taxi_acceptance"},
 {role:"worker",label:"الفنيون ومقدمو الخدمات",event:"service_acceptance"},
 {role:"restaurant",label:"المطاعم",event:"order_acceptance"},
 {role:"hotel",label:"الفنادق",event:"order_acceptance"},
 {role:"store",label:"المتاجر",event:"order_acceptance"},
] as const;
const revenueLabel:Record<string,string>={taxi_commission:"عمولة التكسي",service_commission:"عمولة الفني",order_commission:"عمولة طلب شريك",complaint_deduction:"استقطاع شكوى",wallet_debt_collection:"تحصيل دين المحفظة",admin_credit_reversal:"تسوية إدارية"};
const categoryLabel=(u:UserRow)=>{
 const value=String(u.partner?.partner_type||u.partner?.business_vertical||"").toLowerCase();
 if(value.includes("restaurant")||value.includes("food"))return "مطعم";
 if(value.includes("hotel")||value.includes("hospitality"))return "فندق";
 if(value.includes("store")||value.includes("shop")||value.includes("grocery"))return "متجر";
 const labels:Record<string,string>={driver:"صاحب تكسي",large_driver:"تكسي كبير",worker:"فني",customer:"زبون",restaurant:"مطعم",hotel:"فندق",store:"متجر"};
 return (u.roles??[]).map(r=>labels[r]||r).join("، ")||"مستخدم";
};
const govLabel:Record<string,string>={baghdad:"بغداد",basra:"البصرة",nineveh:"نينوى",erbil:"أربيل",sulaymaniyah:"السليمانية",duhok:"دهوك",kirkuk:"كركوك",najaf:"النجف",karbala:"كربلاء",babil:"بابل",anbar:"الأنبار",diyala:"ديالى",saladin:"صلاح الدين",wasit:"واسط",dhiqar:"ذي قار",maysan:"ميسان",muthanna:"المثنى",qadisiyah:"القادسية"};

export default function AdminRightsScreen(){
 const {user,loading:authLoading}=useAuth();
 const [allowed,setAllowed]=useState<boolean|null>(null);
 const [tab,setTab]=useState<Tab>("wallet");
 const [query,setQuery]=useState("");const [users,setUsers]=useState<UserRow[]>([]);const [selected,setSelected]=useState<UserRow|null>(null);
 const [amount,setAmount]=useState("");const [note,setNote]=useState("");const [kind,setKind]=useState<"debit"|"credit">("debit");
 const [charge,setCharge]=useState("0");const [duration,setDuration]=useState("30");const [reason,setReason]=useState("ميزة خاصة من إدارة ممنون");
 const [policies,setPolicies]=useState<any[]>([]);const [overrides,setOverrides]=useState<any[]>([]);const [revenue,setRevenue]=useState<any[]>([]);const [collections,setCollections]=useState<any[]>([]);const [summary,setSummary]=useState<any>({});
 const [commissionRates,setCommissionRates]=useState<Record<string,string>>({driver:"0",large_driver:"0",worker:"0",restaurant:"0",hotel:"0",store:"0"});
 const [busy,setBusy]=useState(false);const [loading,setLoading]=useState(false);const [error,setError]=useState("");
 const invoke=useCallback(async(body:Record<string,unknown>)=>{const {data,error:callError}=await supabase.functions.invoke("admin-rights",{body});if(callError)throw new Error(callError.message||"تعذر الاتصال بحقوق ممنون");if(data?.error)throw new Error(data.error);return data;},[]);
 const load=useCallback(async()=>{setLoading(true);try{const data=await invoke({action:"list"});const loadedPolicies=data.policies??[];setPolicies(loadedPolicies);setCommissionRates(Object.fromEntries(COMMISSION_CATEGORIES.map(category=>{const specific=loadedPolicies.find((p:any)=>p.scope_type==="role"&&p.scope_key===category.role&&p.collection_event===category.event&&p.is_enabled===true)??loadedPolicies.find((p:any)=>p.scope_type==="role"&&p.scope_key===category.role&&p.collection_event===category.event);const globalPolicy=loadedPolicies.find((p:any)=>p.scope_type==="global"&&p.collection_event===category.event&&p.is_enabled===true)??loadedPolicies.find((p:any)=>p.scope_type==="global"&&p.collection_event===category.event);return [category.role,String(specific?.commission_rate_percent??globalPolicy?.commission_rate_percent??0)];})));setOverrides(data.overrides??[]);setRevenue(data.revenue??[]);setCollections(data.collections??[]);setSummary(data.summary??{});}catch(e:any){setError(String(e?.message||"تعذر تحميل البيانات"));}finally{setLoading(false);}},[invoke]);
 useEffect(()=>{if(authLoading)return;if(!user?.id){setAllowed(false);return;}void supabase.rpc("is_super_admin",{p_user_id:user.id}).then(({data,error:err})=>setAllowed(!err&&data===true));},[authLoading,user?.id]);
 useEffect(()=>{if(allowed&&["special","policies","revenue"].includes(tab))void load();},[allowed,tab,load]);
 const searchUsers=async()=>{if(query.trim().length<2){Alert.alert("البحث","اكتب حرفين أو أكثر");return;}setBusy(true);try{const data=await invoke({action:"search_users",query:query.trim()});setUsers(data.users??[]);setSelected(null);}catch(e:any){Alert.alert("تعذر البحث",String(e?.message||"حاول مرة ثانية"));}finally{setBusy(false);}};
 const adjust=async()=>{if(!selected||!/^\d+$/.test(amount)||Number(amount)<=0||!note.trim()){Alert.alert("تحقق من البيانات","اختار مستخدماً واكتب المبلغ والسبب");return;}Alert.alert("تأكيد العملية",`${kind==="debit"?"استقطاع":"إضافة"} ${Number(amount).toLocaleString("ar-IQ")} د.ع؟`,[{text:"رجوع",style:"cancel"},{text:"تأكيد",onPress:()=>{setBusy(true);const key=globalThis.crypto?.randomUUID?.()||("admin-"+Date.now()+"-"+selected.id);void invoke({action:"wallet_adjust",user_id:selected.id,amount_iqd:Number(amount),type:kind,note:note.trim(),idempotency_key:key}).then(async r=>{Alert.alert("تم",`الرصيد الجديد: ${Number(r.result?.balance_iqd??0).toLocaleString("ar-IQ")} د.ع`);setAmount("");setNote("");await searchUsers();}).catch((e:any)=>Alert.alert("تعذر التنفيذ",String(e?.message||"حاول مرة ثانية"))).finally(()=>setBusy(false));}}]);};
 const saveOverride=async()=>{if(!selected||Number(charge)<0||Number(charge)>100||!reason.trim()){Alert.alert("تحقق من البيانات","تأكد من النسبة والسبب");return;}const end=duration==="permanent"?null:new Date(Date.now()+Number(duration)*86400000).toISOString();setBusy(true);try{await invoke({action:"save_override",user_id:selected.id,charge_percent:Number(charge),starts_at:new Date().toISOString(),ends_at:end,reason:reason.trim()});Alert.alert("تم","تم حفظ الميزة الخاصة");await load();}catch(e:any){Alert.alert("تعذر الحفظ",String(e?.message||"حاول مرة ثانية"));}finally{setBusy(false);}};
 const revokeOverride=(id:string)=>{Alert.alert("إلغاء الميزة","تريد تلغي الإعفاء لهذا المستخدم؟",[{text:"رجوع",style:"cancel"},{text:"إلغاء الميزة",style:"destructive",onPress:()=>{setBusy(true);void invoke({action:"revoke_override",override_id:id}).then(async()=>{Alert.alert("تم","تم إلغاء الميزة");await load();}).catch((e:any)=>Alert.alert("تعذر التنفيذ",String(e?.message||"حاول مرة ثانية"))).finally(()=>setBusy(false));}}]);};
 const saveCategoryPolicy=async(category:typeof COMMISSION_CATEGORIES[number])=>{const raw=commissionRates[category.role]??"0";const percent=Number(raw);if(!Number.isFinite(percent)||percent<0||percent>100){Alert.alert("نسبة غير صحيحة","اكتب نسبة من 0 إلى 100.");return;}setBusy(true);try{await invoke({action:"save_policy",scope_type:"role",scope_key:category.role,commission_rate_percent:percent,commission_charge_percent:100,collection_event:category.event,free_trial_enabled:false,free_trial_days:0,new_users_only:false,is_enabled:true,starts_at:new Date().toISOString(),ends_at:null});Alert.alert("تم الحفظ","انحفظت نسبة "+category.label+" وحدها.");await load();}catch(e:any){Alert.alert("تعذر الحفظ",String(e?.message||"تحقق من الإعدادات"));}finally{setBusy(false);}};
 if(authLoading||allowed===null)return <View style={s.center}><ActivityIndicator color={palette.brand}/><Text style={s.muted}>جارٍ التحقق من الصلاحية...</Text></View>;
 if(!allowed)return <View style={s.center}><Text style={s.title}>غير مصرّح</Text></View>;
 return <View style={s.page}><Stack.Screen options={{title:"حقوق ممنون"}}/>
  <View style={s.header}><Text style={s.title}>حقوق ممنون</Text><Text style={s.muted}>المحافظ والعمولات والإعفاءات والإيرادات</Text></View>
  <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={s.tabs}>
   {([["wallet","المحفظة"],["special","ميزات خاصة"],["policies","إعدادات الاستقطاع"],["revenue","الإيرادات"]] as [Tab,string][]).map(([k,l])=><TouchableOpacity key={k} onPress={()=>setTab(k)} style={[s.tab,tab===k&&s.active]}><Text style={[s.tabText,tab===k&&s.activeText]}>{l}</Text></TouchableOpacity>)}
  </ScrollView>
  {!!error&&<Text style={s.error}>{error}</Text>}
  <ScrollView contentContainerStyle={s.content} refreshControl={<RefreshControl refreshing={loading} onRefresh={()=>void load()}/>}>
   {(tab==="wallet"||tab==="special")&&<View style={s.card}><Text style={s.cardTitle}>البحث عن مستخدم</Text><View style={s.row}><TextInput value={query} onChangeText={setQuery} placeholder="الاسم أو رقم الهاتف" placeholderTextColor={palette.muted} style={[s.input,{flex:1}]}/><TouchableOpacity onPress={()=>void searchUsers()} style={s.primary}><Text style={s.primaryText}>بحث</Text></TouchableOpacity></View>
    {users.map(u=><TouchableOpacity key={u.id} onPress={()=>setSelected(u)} style={[s.userCard,selected?.id===u.id&&s.selected]}><Text style={s.cardTitle}>{u.full_name||"مستخدم ممنون"}</Text><Text style={s.muted}>{u.phone||u.email} · {categoryLabel(u)}</Text><Text style={s.muted}>الرصيد {Number(u.balance_iqd).toLocaleString("ar-IQ")} د.ع · {govLabel[u.governorate_key||""]||u.governorate_key||"بلا محافظة"}</Text></TouchableOpacity>)}
    {selected&&<View style={s.panel}><Text style={s.cardTitle}>{selected.full_name||selected.phone}</Text>
     {tab==="wallet"?<>
      <View style={s.row}><TouchableOpacity onPress={()=>setKind("debit")} style={[s.choice,kind==="debit"&&s.active]}><Text style={[s.tabText,kind==="debit"&&s.activeText]}>استقطاع شكوى</Text></TouchableOpacity><TouchableOpacity onPress={()=>setKind("credit")} style={[s.choice,kind==="credit"&&s.active]}><Text style={[s.tabText,kind==="credit"&&s.activeText]}>إضافة رصيد</Text></TouchableOpacity></View>
      <TextInput value={amount} onChangeText={setAmount} keyboardType="number-pad" placeholder="المبلغ بالدينار" placeholderTextColor={palette.muted} style={s.input}/>
      <TextInput value={note} onChangeText={setNote} placeholder="سبب العملية" placeholderTextColor={palette.muted} style={s.input}/>
      <TouchableOpacity disabled={busy} onPress={()=>void adjust()} style={s.primary}><Text style={s.primaryText}>{busy?"جارٍ التنفيذ...":"تأكيد العملية"}</Text></TouchableOpacity>
     </>:<>
      <Text style={s.muted}>نسبة تحصيل عمولة ممنون من ٠٪ إلى ١٠٠٪</Text><TextInput value={charge} onChangeText={setCharge} keyboardType="decimal-pad" placeholder="0" style={s.input}/>
      <Text style={s.muted}>المدة</Text><View style={s.rowWrap}>{durations.map(d=><TouchableOpacity key={d.value} onPress={()=>setDuration(d.value)} style={[s.choice,duration===d.value&&s.active]}><Text style={[s.tabText,duration===d.value&&s.activeText]}>{d.label}</Text></TouchableOpacity>)}</View>
      <TextInput value={reason} onChangeText={setReason} style={s.input} placeholder="سبب الميزة"/>
      <TouchableOpacity disabled={busy} onPress={()=>void saveOverride()} style={s.primary}><Text style={s.primaryText}>حفظ الميزة</Text></TouchableOpacity>
     </>}
    </View>}
    {tab==="special"&&<View style={{borderTopWidth:1,borderTopColor:palette.line,paddingTop:10,gap:8}}><Text style={s.cardTitle}>الميزات الخاصة السارية</Text>{overrides.map(o=><View key={o.id} style={s.userCard}><Text style={s.cardTitle}>{o.profile?.full_name||o.profile?.phone||"مستخدم"}</Text><Text style={s.muted}>تحصيل {o.commission_charge_percent}% · {o.ends_at?new Date(o.ends_at).toLocaleDateString("ar-IQ"):"دائم"}</Text><TouchableOpacity onPress={()=>revokeOverride(o.id)} style={s.primary}><Text style={s.primaryText}>إلغاء الميزة</Text></TouchableOpacity></View>)}{!overrides.length&&<Text style={s.muted}>لا توجد ميزات خاصة سارية</Text>}</View>}
   </View>}
   {tab==="policies"&&<View style={s.card}><Text style={s.cardTitle}>نسبة الاستقطاع حسب الفئة</Text><Text style={s.muted}>كل فئة إلها نسبة مستقلة وزر حفظ خاص بيها. النسبة 0٪ تعني عدم استقطاع عمولة من هذه الفئة. ماكو نسبة خصم إضافية؛ الاستقطاع يحسب من النسبة المحددة فقط.</Text>
    {COMMISSION_CATEGORIES.map(category=>{const current=policies.find((p:any)=>p.scope_type==="role"&&p.scope_key===category.role&&p.collection_event===category.event);return <View key={category.role} style={s.userCard}><Text style={s.cardTitle}>{category.label}</Text><Text style={s.muted}>نسبة استقطاع ممنون من قيمة الطلب (%)</Text><TextInput value={commissionRates[category.role]??"0"} onChangeText={v=>setCommissionRates(old=>({...old,[category.role]:v}))} keyboardType="decimal-pad" placeholder="0 إلى 100" style={s.input}/><Text style={s.muted}>{current?"آخر نسبة محفوظة: "+Number(current.commission_rate_percent||0)+"٪ · "+(current.is_enabled?"مفعّلة":"متوقفة"):"ماكو تخصيص مستقل محفوظ؛ تُستخدم النسبة العامة إن وجدت."}</Text><TouchableOpacity disabled={busy} onPress={()=>void saveCategoryPolicy(category)} style={[s.primary,busy&&{opacity:0.55}]}><Text style={s.primaryText}>{busy?"جارٍ الحفظ...":"حفظ نسبة "+category.label+" فقط"}</Text></TouchableOpacity></View>;})}
    <Text style={s.muted}>كل حفظ يحدّث فئة واحدة فقط ولا يغيّر نسب بقية الفئات. النسبة المحفوظة تطبق على العمليات الجديدة بعد لحظة الاستقطاع المعتمدة.</Text>
   </View>}
   {tab==="revenue"&&<View style={s.card}><Text style={s.cardTitle}>دفتر الإيرادات</Text><View style={s.panel}><Text style={s.muted}>إجمالي إيرادات ممنون المحصلة</Text><Text style={s.title}>{Number(summary.collected_iqd||0).toLocaleString("ar-IQ")} د.ع</Text><Text style={s.muted}>منها تحصيل ديون جديدة عبر زين كاش: {Number(summary.zaincash_debt_collected_iqd||0).toLocaleString("ar-IQ")} د.ع</Text><Text style={s.muted}>ديون مستحقة لممنون: {Number(summary.outstanding_iqd||0).toLocaleString("ar-IQ")} د.ع</Text></View><Text style={s.cardTitle}>تحصيلات زين كاش المؤكدة</Text>{collections.map(x=><View key={x.id} style={s.userCard}><Text style={s.cardTitle}>{Number(x.amount_iqd).toLocaleString("ar-IQ")} د.ع</Text><Text style={s.muted}>مرجع زين كاش: {x.provider_reference} · {new Date(x.created_at).toLocaleString("ar-IQ")}</Text></View>)}<Text style={s.cardTitle}>العمولات والاستقطاعات</Text>{revenue.map(r=><View key={r.id} style={s.userCard}><Text style={s.cardTitle}>{r.profile?.full_name||r.profile?.phone||"مستخدم"}</Text><Text style={s.muted}>{revenueLabel[r.revenue_type]||r.revenue_type} · {new Date(r.created_at).toLocaleString("ar-IQ")}</Text><Text style={s.muted}>مستحق {Number(r.assessed_iqd).toLocaleString("ar-IQ")} · محصل {Number(r.collected_iqd).toLocaleString("ar-IQ")} · معفى {Number(r.waived_iqd).toLocaleString("ar-IQ")}</Text></View>)}{!revenue.length&&<Text style={s.muted}>لا توجد إيرادات مسجلة</Text>}</View>}
  </ScrollView>
 </View>;
}

const s=StyleSheet.create({
 page:{flex:1,backgroundColor:palette.pageCanvas},header:{padding:space.lg,gap:4},title:{fontSize:21,fontWeight:"900",color:palette.ink,textAlign:"right"},muted:{fontSize:11,color:palette.muted,textAlign:"right",lineHeight:18},
 center:{flex:1,justifyContent:"center",alignItems:"center",backgroundColor:palette.pageCanvas,gap:10},tabs:{paddingHorizontal:space.lg,paddingBottom:space.sm,gap:7},tab:{paddingHorizontal:13,paddingVertical:10,borderRadius:30,backgroundColor:palette.surface,borderWidth:1,borderColor:palette.line},active:{backgroundColor:palette.brand,borderColor:palette.brand},tabText:{fontSize:10,fontWeight:"900",color:palette.ink},activeText:{color:palette.white},
 content:{padding:space.lg,gap:12,paddingBottom:50},card:{backgroundColor:palette.surface,borderWidth:1,borderColor:palette.line,borderRadius:radius.lg,padding:14,gap:10},cardTitle:{fontSize:13,fontWeight:"900",color:palette.ink,textAlign:"right"},row:{flexDirection:"row",alignItems:"center",gap:8},rowWrap:{flexDirection:"row",flexWrap:"wrap",gap:7},input:{backgroundColor:palette.pageCanvas,borderWidth:1,borderColor:palette.line,borderRadius:radius.md,padding:12,color:palette.ink,textAlign:"right",fontSize:12,minHeight:42},primary:{backgroundColor:palette.brand,padding:13,borderRadius:radius.md,alignItems:"center",justifyContent:"center"},primaryText:{color:palette.white,fontWeight:"900",fontSize:11},userCard:{padding:12,borderRadius:radius.md,borderWidth:1,borderColor:palette.line,gap:4},selected:{borderColor:palette.brand,backgroundColor:palette.brandSoft},panel:{backgroundColor:palette.brandSoft,borderRadius:radius.md,padding:12,gap:9},choice:{paddingHorizontal:11,paddingVertical:9,borderRadius:12,borderWidth:1,borderColor:palette.line,backgroundColor:palette.surface},error:{color:palette.danger,textAlign:"right",paddingHorizontal:space.lg,fontSize:11},
});
