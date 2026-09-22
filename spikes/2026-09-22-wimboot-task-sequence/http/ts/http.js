// http.js - minimal HTTP GET for WinPE (no curl/PowerShell in stock boot.wim).
// usage: cscript //nologo http.js <url> [-o outfile] [key=value ...]
//   key=value pairs are URL-encoded and appended as a query string.
var a = WScript.Arguments, url = a(0), out = null, q = [];
for (var i = 1; i < a.length; i++) {
  if (a(i) == "-o") { out = a(++i); continue; }
  var kv = a(i).replace(/\r/g, ""), p = kv.indexOf("=");
  q.push(encodeURIComponent(kv.substr(0, p)) + "=" + encodeURIComponent(kv.substr(p + 1)));
}
if (q.length) url += (url.indexOf("?") < 0 ? "?" : "&") + q.join("&");
var x;
try { x = new ActiveXObject("MSXML2.ServerXMLHTTP.6.0"); }
catch (e) { x = new ActiveXObject("MSXML2.XMLHTTP.6.0"); }
x.open("GET", url, false);
x.send();
if (x.status != 200) { WScript.StdErr.WriteLine("HTTP " + x.status + " " + url); WScript.Quit(1); }
if (out) {
  var f = new ActiveXObject("Scripting.FileSystemObject").CreateTextFile(out, true);
  f.Write(x.responseText); f.Close();
} else { WScript.StdOut.Write(x.responseText); }
