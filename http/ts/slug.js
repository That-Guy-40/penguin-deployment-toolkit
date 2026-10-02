// slug.js - print the model slug of this machine: the SMBIOS product name,
// lowercased, every run of other characters turned into one "-".
//   "Latitude 5440" -> latitude-5440     "Standard PC (Q35 + ICH9, 2009)" -> standard-pc-q35-ich9-2009
// The server keeps per-model defaults in models/<slug>.cfg. The slug a machine
// computed is reported as model= on its ts-start event (bin/status).
var p = "";
try { p = new ActiveXObject("WScript.Shell").RegRead("HKLM\\HARDWARE\\DESCRIPTION\\System\\BIOS\\SystemProductName"); } catch (e) {}
WScript.Echo(String(p).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, ""));
