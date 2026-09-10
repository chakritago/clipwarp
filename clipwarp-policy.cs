// Shared, dependency-free policy for Windows PowerShell 5.1 and PowerShell 7.
namespace ClipwarpPolicy {
using System;
using System.IO;
using System.Text;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Threading;
using System.Text.RegularExpressions;
using System.Runtime.InteropServices;

    public sealed class ConfigSnapshot {
        public string Json { get; internal set; }
        public string Status { get; internal set; }
        public string Diagnostic { get; internal set; }
        public bool IsUsable { get; internal set; }
        public bool Paused { get; internal set; }
        public bool ActionsEnabled { get; internal set; }
        public bool CalendarEnabled { get; internal set; }
        public bool ChatGptEnabled { get; internal set; }
        public bool RunCommandEnabled { get; internal set; }
        public string TargetMode { get; internal set; }
        public int RetentionDays { get; internal set; }
        public int PopupDurationSeconds { get; internal set; }
        public Dictionary<string, object> Data { get; internal set; }
    }

    // Bounded strict JSON reader: no edition-specific serializer, comments, duplicate keys,
    // trailing tokens, NaN, or regex-based extraction of nested configuration.
    public static class Json {
        public static object Parse(string text) { return new Reader(text).Read(); }
        public static string Stringify(object value) { var b=new StringBuilder(); Write(b,value,0); return b.ToString(); }
        static void Write(StringBuilder b, object v, int depth) {
            if(depth>32) throw new FormatException("JSON nesting exceeds 32.");
            if(v==null){b.Append("null");return;}
            if(v is string){ b.Append('"'); foreach(char c in (string)v){switch(c){case '"':b.Append("\\\"");break;case '\\':b.Append("\\\\");break;case '\n':b.Append("\\n");break;case '\r':b.Append("\\r");break;case '\t':b.Append("\\t");break;default:if(c<32)b.Append("\\u"+((int)c).ToString("x4"));else b.Append(c);break;}}b.Append('"');return; }
            if(v is bool){b.Append((bool)v?"true":"false");return;}
            var d=v as Dictionary<string,object>; if(d!=null){ b.Append('{');bool first=true;foreach(var p in d){if(!first)b.Append(',');first=false;Write(b,p.Key,depth+1);b.Append(':');Write(b,p.Value,depth+1);}b.Append('}');return; }
            var a=v as IList; if(a!=null){b.Append('[');for(int i=0;i<a.Count;i++){if(i>0)b.Append(',');Write(b,a[i],depth+1);}b.Append(']');return;}
            b.Append(Convert.ToString(v,CultureInfo.InvariantCulture));
        }
        sealed class Reader {
            readonly string s; int i;
            public Reader(string text){s=text??"";if(s.Length>1048576)throw new FormatException("Config exceeds 1 MiB.");}
            public object Read(){object v=Value(0);Space();if(i!=s.Length)Bad();return v;}
            void Bad(){throw new FormatException("Invalid JSON at offset "+i+".");}
            void Space(){while(i<s.Length && (s[i]==' '||s[i]=='\r'||s[i]=='\n'||s[i]=='\t'))i++;}
            bool Eat(char c){Space();if(i<s.Length&&s[i]==c){i++;return true;}return false;}
            object Value(int depth){
                if(depth>32)throw new FormatException("JSON nesting exceeds 32.");Space();if(i>=s.Length){Bad();return null;}
                char c=s[i];if(c=='"')return Str();
                if(c=='{'){i++;var d=new Dictionary<string,object>(StringComparer.Ordinal);if(Eat('}'))return d;do{Space();if(i>=s.Length||s[i]!='"')Bad();string k=Str();if(d.ContainsKey(k)||!Eat(':'))Bad();d.Add(k,Value(depth+1));if(Eat('}'))return d;}while(Eat(','));Bad();}
                if(c=='['){i++;var a=new List<object>();if(Eat(']'))return a;do{a.Add(Value(depth+1));if(Eat(']'))return a;}while(Eat(','));Bad();}
                foreach(string word in new[]{"true","false","null"})if(i+word.Length<=s.Length && String.CompareOrdinal(s,i,word,0,word.Length)==0){i+=word.Length;return word=="null"?null:(object)(word=="true");}
                int start=i;if(s[i]=='-')i++;if(i>=s.Length)Bad();if(s[i]=='0')i++;else{if(s[i]<'1'||s[i]>'9')Bad();while(i<s.Length&&s[i]>='0'&&s[i]<='9')i++;}
                if(i<s.Length&&s[i]=='.'){i++;int p=i;while(i<s.Length&&s[i]>='0'&&s[i]<='9')i++;if(p==i)Bad();}
                if(i<s.Length&&(s[i]=='e'||s[i]=='E')){i++;if(i<s.Length&&(s[i]=='+'||s[i]=='-'))i++;int p=i;while(i<s.Length&&s[i]>='0'&&s[i]<='9')i++;if(p==i)Bad();}
                string n=s.Substring(start,i-start);long l;if(Int64.TryParse(n,NumberStyles.AllowLeadingSign,CultureInfo.InvariantCulture,out l))return l;
                decimal x;if(!Decimal.TryParse(n,NumberStyles.Float,CultureInfo.InvariantCulture,out x))Bad();return x;
            }
            string Str(){i++;var b=new StringBuilder();while(i<s.Length){char c=s[i++];if(c=='"')return b.ToString();if(c<32)Bad();if(c=='\\'){if(i>=s.Length)Bad();c=s[i++];switch(c){case '"':case '\\':case '/':break;case 'b':c='\b';break;case 'f':c='\f';break;case 'n':c='\n';break;case 'r':c='\r';break;case 't':c='\t';break;case 'u':if(i+4>s.Length)Bad();int code;if(!Int32.TryParse(s.Substring(i,4),NumberStyles.HexNumber,CultureInfo.InvariantCulture,out code))Bad();c=(char)code;i+=4;break;default:Bad();break;}}b.Append(c);}Bad();return null;}
        }
    }

    public static class ConfigStore {
        public const int SchemaVersion=2;
        public static readonly string[] Modes={"auto","chatgpt","claude","image-only","dual","text","web"};
        static Dictionary<string,object> Obj(){return new Dictionary<string,object>(StringComparer.Ordinal);}
        public static object Get(Dictionary<string,object> d,string path,object fallback){object v=d;foreach(string k in path.Split('.')){var o=v as Dictionary<string,object>;if(o==null||!o.TryGetValue(k,out v))return fallback;}return v;}
        static void Put(Dictionary<string,object> d,string path,object value){string[] keys=path.Split('.');for(int i=0;i<keys.Length-1;i++){object v;Dictionary<string,object> child;if(!d.TryGetValue(keys[i],out v)){child=Obj();d[keys[i]]=child;}else{child=v as Dictionary<string,object>;if(child==null)throw new FormatException("Expected object: "+keys[i]);}d=child;}d[keys[keys.Length-1]]=value;}
        static void Default(Dictionary<string,object>d,string p,object v){if(Get(d,p,null)==null){ // Explicit null is invalid, not a missing default.
                object current=d;bool exists=true;foreach(string k in p.Split('.')){var o=current as Dictionary<string,object>;if(o==null||!o.TryGetValue(k,out current)){exists=false;break;}}if(exists)throw new FormatException("Null policy field: "+p);Put(d,p,v);}}
        static void Bool(Dictionary<string,object>d,string p,bool fallback){Default(d,p,fallback);if(!(Get(d,p,null) is bool))throw new FormatException("Expected boolean: "+p);}
        static void Number(Dictionary<string,object>d,string p,long fallback,long min,long max){Default(d,p,fallback);object v=Get(d,p,null);if(!(v is long)|| (long)v<min||(long)v>max)throw new FormatException("Invalid integer: "+p);}
        static void Choice(Dictionary<string,object>d,string p,string fallback,string[] choices){Default(d,p,fallback);var v=Get(d,p,null) as string;if(v==null||Array.IndexOf(choices,v)<0)throw new FormatException("Invalid choice: "+p);}
        static Dictionary<string,object> Validate(Dictionary<string,object>d){
            if(d==null)throw new FormatException("Config root must be an object.");
            Number(d,"version",1,1,SchemaVersion);
            foreach(string name in new[]{"calendar","actions","retention","targetOverrides","imageLimits","popup"}){object v;if(d.TryGetValue(name,out v)&&!(v is Dictionary<string,object>))throw new FormatException("Expected object: "+name);}
            Bool(d,"paused",false);Choice(d,"targetMode","auto",Modes);Bool(d,"calendar.enabled",true);
            Choice(d,"calendar.imageDetails","Disabled",new[]{"Disabled","Filename","FullPath"});Number(d,"calendar.defaultDurationMinutes",60,1,1440);
            // Old calendar.enabled was the master popup switch. Never migrate disabled
            // legacy actions to enabled; new action switches are independent thereafter.
            bool legacy=(bool)Get(d,"calendar.enabled",true);
            Bool(d,"actions.enabled",legacy);Bool(d,"actions.calendar",legacy);Bool(d,"actions.chatgpt",legacy);Bool(d,"actions.runCommand",legacy);
            Number(d,"popup.durationSeconds",10,3,300);
            Number(d,"retentionDays",0,0,3650);long days=(long)Get(d,"retentionDays",0L);
            Bool(d,"retention.enabled",days>0);Number(d,"retention.maxAgeDays",days,0,3650);Number(d,"retention.maxCount",0,0,1000000);Number(d,"retention.maxBytes",0,0,1099511627776L);
            Number(d,"imageLimits.maxSourceBytes",33554432,1024,268435456);Number(d,"imageLimits.maxDimension",16384,1,32768);Number(d,"imageLimits.maxWidth",16384,1,32768);Number(d,"imageLimits.maxHeight",16384,1,32768);Number(d,"imageLimits.maxPixels",40000000,1,100000000);Number(d,"imageLimits.maxDecodedBytes",160000000,4,400000000);
            Default(d,"targetOverrides",Obj());var overrides=(Dictionary<string,object>)d["targetOverrides"];var names=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach(var p in overrides){if(!Regex.IsMatch(p.Key,@"^[a-zA-Z0-9_.-]{1,128}$")||!names.Add(TargetPolicy.NormalizeProcess(p.Key))||!(p.Value is string)||Array.IndexOf(Modes,(string)p.Value)<0)throw new FormatException("Invalid target override.");}
            d["version"]=(long)SchemaVersion;return d;
        }
        static ConfigSnapshot Snapshot(Dictionary<string,object>d,string status,bool usable,string diagnostic){
            return new ConfigSnapshot{Data=d,Json=Json.Stringify(d),Status=status,IsUsable=usable,Diagnostic=diagnostic,Paused=!usable||(bool)Get(d,"paused",false),ActionsEnabled=usable&&(bool)Get(d,"actions.enabled",false),CalendarEnabled=usable&&(bool)Get(d,"actions.enabled",false)&&(bool)Get(d,"actions.calendar",false),ChatGptEnabled=usable&&(bool)Get(d,"actions.enabled",false)&&(bool)Get(d,"actions.chatgpt",false),RunCommandEnabled=usable&&(bool)Get(d,"actions.enabled",false)&&(bool)Get(d,"actions.runCommand",false),TargetMode=(string)Get(d,"targetMode","auto"),RetentionDays=usable&&(bool)Get(d,"retention.enabled",false)?(int)(long)Get(d,"retention.maxAgeDays",0L):0,PopupDurationSeconds=(int)(long)Get(d,"popup.durationSeconds",10L)};
        }
        static Dictionary<string,object> Load(string path){using(var f=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read)){if(f.Length>1048576)throw new FormatException("Config exceeds 1 MiB.");using(var r=new StreamReader(f,new UTF8Encoding(false,true),true))return Validate(Json.Parse(r.ReadToEnd()) as Dictionary<string,object>);}}
        static ConfigSnapshot ReadCore(string path){
            try{return Snapshot(Load(path),"valid",true,"");}
            catch(FileNotFoundException){return Snapshot(Validate(Obj()),"missing",true,"Configuration missing; defaults in use.");}
            catch(DirectoryNotFoundException){return Snapshot(Validate(Obj()),"missing",true,"Configuration missing; defaults in use.");}
            catch(Exception e){if(!(e is IOException)&&!(e is UnauthorizedAccessException)&&!(e is FormatException)&&!(e is DecoderFallbackException))throw;
                string kind=e is FormatException||e is DecoderFallbackException?"corrupt":"unreadable";
                try{return Snapshot(Load(path+".bak"),"backup",true,"Primary configuration "+kind+"; using validated backup. Original retained.");}catch(Exception b){if(!(b is IOException)&&!(b is UnauthorizedAccessException)&&!(b is FormatException)&&!(b is DecoderFallbackException))throw;}
                var safe=Validate(Obj());Put(safe,"paused",true);Put(safe,"actions.enabled",false);Put(safe,"actions.calendar",false);Put(safe,"actions.chatgpt",false);Put(safe,"actions.runCommand",false);Put(safe,"calendar.enabled",false);
                return Snapshot(safe,kind,false,"Configuration "+kind+" and no valid backup; automatic work paused. Original retained.");
            }
        }
        static string MutexName(string path){string user;try{user=WindowsIdentity.GetCurrent().User.Value;}catch{user=Environment.UserName;}using(var sha=SHA256.Create())return @"Local\Clipwarp.Config."+BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(user+"|"+Path.GetFullPath(path).ToUpperInvariant()))).Replace("-","");}
        static T Locked<T>(string path,Func<T> action){using(var mutex=new Mutex(false,MutexName(path))){bool owned=false;try{try{owned=mutex.WaitOne(10000);}catch(AbandonedMutexException){owned=true;}if(!owned)throw new TimeoutException("Configuration is busy.");return action();}finally{if(owned)mutex.ReleaseMutex();}}}
        public static ConfigSnapshot Read(string path){return Locked(path,delegate{return ReadCore(path);});}
        static void WriteCore(string path,Dictionary<string,object> d,ConfigSnapshot previous){
            if(!previous.IsUsable)throw new InvalidOperationException("Refusing to overwrite invalid configuration; repair or move it explicitly first.");
            string full=Path.GetFullPath(path),dir=Path.GetDirectoryName(full);Directory.CreateDirectory(dir);string temp=Path.Combine(dir,".clipwarp-config-"+Guid.NewGuid().ToString("N")+".tmp");
            try{byte[] bytes=new UTF8Encoding(false,true).GetBytes(Json.Stringify(Validate(d)));using(var f=new FileStream(temp,FileMode.CreateNew,FileAccess.Write,FileShare.None)){f.Write(bytes,0,bytes.Length);f.Flush(true);}
                if(previous.Status=="missing")File.Move(temp,full);
                else if(previous.Status=="backup"){string evidence=full+".corrupt-"+Guid.NewGuid().ToString("N");File.Replace(temp,full,evidence,true);}
                else File.Replace(temp,full,full+".bak",true);
            }finally{if(File.Exists(temp))File.Delete(temp);}
        }
        public static ConfigSnapshot Update(string path,string property,string jsonValue){return Locked(path,delegate{var previous=ReadCore(path);var d=previous.Data;object value=Json.Parse(jsonValue);if(String.IsNullOrEmpty(property)||property.StartsWith(".")||property.EndsWith(".")||property.Contains(".."))throw new ArgumentException("Invalid property path.");Put(d,property,value);
                if(property=="calendar.enabled")Put(d,"actions.calendar",value);
                if(property=="actions.calendar")Put(d,"calendar.enabled",value);
                if(property=="retentionDays"){Put(d,"retention.maxAgeDays",value);Put(d,"retention.enabled",value is long&&(long)value>0);}
                if(property=="retention.maxAgeDays")Put(d,"retentionDays",value);
                if(property=="retention" && value is Dictionary<string,object>){object age; if(((Dictionary<string,object>)value).TryGetValue("maxAgeDays",out age))Put(d,"retentionDays",age);}
                WriteCore(path,d,previous);return ReadCore(path);});}
        // Explicit whole-document save. Setters must use Update to prevent lost updates.
        public static ConfigSnapshot SaveJson(string path,string json){return Locked(path,delegate{var previous=ReadCore(path);var d=Validate(Json.Parse(json) as Dictionary<string,object>);WriteCore(path,d,previous);return ReadCore(path);});}
    }

    public sealed class TargetInfo {
        public string ProcessName="", WindowTitle="", WindowClass="";
        public uint ProcessId;
        public bool HasFilePickerControls;
        public bool IsChatGpt {get{return TargetPolicy.IsChatGpt(ProcessName,WindowTitle);}}
    }
    public sealed class TargetDecision { public string Mode; public string Reason; public string MatchedRule; public string ProcessName; }
    public static class TargetPolicy {
        const string Browsers=@"^(chrome|msedge|firefox|brave|opera|vivaldi|arc|zen|waterfox|floorp|librewolf|thorium|chromium|chatgpt)$";
        const string Ides=@"^(code|cursor|windsurf|idea|idea64|pycharm|pycharm64|webstorm|webstorm64|phpstorm|phpstorm64|rider|rider64|clion|clion64|goland|goland64|rubymine|rubymine64|rustrover|rustrover64|datagrip|datagrip64|studio64|fleet)$";
        const string TerminalWords=@"(^|[\s\-_–—|•·●:\[(])(terminal|claude|powershell|pwsh|cmd(\.exe)?|bash|zsh|wsl)([\s\-_–—|•·●:)\]]|$)";
        const string PickerWords=@"(^|[\s\-_–—|•·:\[(])(open|save|save\s*as|select(\s*a)?\s*file|choose(\s*a)?\s*file|upload(\s*a)?\s*file|file\s*upload|browse|select\s*folder|choose\s*folder|all\s*files|öffnen|speichern|speichern\s*unter|datei(en)?\s*auswählen|ouvrir|enregistrer|enregistrer\s*sous|sélectionner\s*un\s*fichier|choisir\s*un\s*fichier|abrir|guardar|guardar\s*como|seleccionar\s*archivo|elegir\s*archivo|apri|salva|salva\s*con\s*nome|seleziona\s*file|salvar|salvar\s*como|открыть|сохранить|сохранить\s*как|выбор\s*файла|выбрать\s*файл|開く|保存|名前を付けて保存|ファイルの選択|ファイルを開く|ファイルの保存|打开|另存为|选择文件|上传文件|瀏覽|開啟|儲存|另存新檔|選擇檔案|上傳檔案|열기|저장|다른\s*이름으로\s*저장|파일\s*선택|파일\s*열기|เปิด|บันทึก|บันทึกเป็น|เลือกไฟล์|เลือกโฟลเดอร์|อัปโหลด)([\s\-_–—|•·:)\]]|$)";
        static bool Match(string text,string pattern){return Regex.IsMatch(text??"",pattern,RegexOptions.IgnoreCase|RegexOptions.CultureInvariant,TimeSpan.FromMilliseconds(100));}
        public static string NormalizeProcess(string p){p=p??"";return p.EndsWith(".exe",StringComparison.OrdinalIgnoreCase)?p.Substring(0,p.Length-4):p;}
        public static bool IsChatGpt(string p,string title){p=NormalizeProcess(p);return String.Equals(p,"chatgpt",StringComparison.OrdinalIgnoreCase)||(Match(p,Browsers)&&Match(title,@"chatgpt|openai|(^|[\s\-_–—|•·])new\s*chat([\s\-_–—|•·]|$)|การสนทนาใหม่|แชทใหม่"));}
        public static bool IsWeb(string p,string title){return Match(NormalizeProcess(p),Browsers);}
        public static bool IsTerminal(string p,string title){p=NormalizeProcess(p);if(Match(p,Browsers))return false;if(Match(p,@"^(windowsterminal|powershell|pwsh|cmd|conhost|mintty|bash|alacritty|wezterm|hyper|tabby)$"))return true;return Match(title,TerminalWords);}
        public static bool IsFilePicker(string p,string title,string cls,bool controls){p=NormalizeProcess(p);if(String.Equals(p,"pickerhost",StringComparison.OrdinalIgnoreCase))return true;if(cls=="#32770"&&(controls||String.IsNullOrWhiteSpace(title)||Match(title,PickerWords)))return true;return !Match(p,Browsers)&&!Match(p,Ides)&&Match(title,PickerWords);}
        static string Mode(string mode){if(mode=="chatgpt"||mode=="web")return "image-only";if(mode=="claude")return "dual";return mode;}
        static TargetDecision Decision(string mode,string rule,string reason,string p){return new TargetDecision{Mode=Mode(mode),MatchedRule=rule,Reason=reason,ProcessName=p??""};}
        public static TargetDecision Explain(ConfigSnapshot config,string requested,bool imageOnly,bool keepImage,string p,string title,string cls,bool controls){
            p=NormalizeProcess(p);if(imageOnly)return Decision("image-only","argument.imageOnly","Explicit image-only switch.",p);
            if(!String.IsNullOrEmpty(requested)&&requested!="auto"){if(Array.IndexOf(ConfigStore.Modes,requested)<0)throw new ArgumentException("Invalid target mode.");return Decision(requested,"argument.target","Explicit target argument.",p);}
            if(config!=null&&config.TargetMode!="auto")return Decision(config.TargetMode,"config.targetMode","Configured global target.",p);
            if(config!=null){var overrides=ConfigStore.Get(config.Data,"targetOverrides",null) as Dictionary<string,object>;if(overrides!=null)foreach(var entry in overrides)if(String.Equals(NormalizeProcess(entry.Key),p,StringComparison.OrdinalIgnoreCase)&&((string)entry.Value)!="auto")return Decision((string)entry.Value,"config.targetOverrides."+entry.Key,"Exact process override.",p);}
            if(IsFilePicker(p,title,cls,controls))return Decision("dual",controls?"target.filePickerControls":"target.filePicker","Windows file picker requires a file path.",p);
            if(IsTerminal(p,title))return Decision("dual","target.terminal","Terminal target requires a file path.",p);
            if(!String.IsNullOrEmpty(p)||!String.IsNullOrEmpty(title))return Decision("image-only","target.default","Other application receives an image.",p);
            return Decision(keepImage?"dual":"text","target.unknown","No foreground target; preserve explicit keep-image behavior.",p);
        }
        [DllImport("user32.dll")]static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern int GetWindowText(IntPtr h,StringBuilder b,int n);
        [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern int GetClassName(IntPtr h,StringBuilder b,int n);
        [DllImport("user32.dll")]static extern uint GetWindowThreadProcessId(IntPtr h,out uint id);
        delegate bool EnumProc(IntPtr h,IntPtr param);
        [DllImport("user32.dll")]static extern bool EnumChildWindows(IntPtr h,EnumProc callback,IntPtr param);
        [DllImport("user32.dll")]static extern int GetDlgCtrlID(IntPtr h);
        public static TargetInfo CaptureForeground(){var info=new TargetInfo();try{IntPtr h=GetForegroundWindow();if(h==IntPtr.Zero)return info;GetWindowThreadProcessId(h,out info.ProcessId);try{using(var process=System.Diagnostics.Process.GetProcessById((int)info.ProcessId))info.ProcessName=process.ProcessName;}catch{}var b=new StringBuilder(2048);GetWindowText(h,b,b.Capacity);info.WindowTitle=b.ToString();b.Length=0;GetClassName(h,b,b.Capacity);info.WindowClass=b.ToString();if(info.WindowClass=="#32770"){bool filename=false,shell=false;int count=0;EnumChildWindows(h,delegate(IntPtr child,IntPtr unused){if(++count>256)return false;int id=GetDlgCtrlID(child);var c=new StringBuilder(128);GetClassName(child,c,c.Capacity);string name=c.ToString();if(id==0x480||id==0x47c||id==0x47f)filename=true;if(name=="SHELLDLL_DefView"||name=="DirectUIHWND")shell=true;return true;},IntPtr.Zero);info.HasFilePickerControls=filename&&shell;}}catch{}return info;}
    }
}
