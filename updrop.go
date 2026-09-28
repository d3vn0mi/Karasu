// =============================================================================
//
//	updrop  (Go)  |  the Yatagarasu file-drop server
//	Author: d3vn0mi
//	Streaming HTTP file server: folder-aware browse, upload, and zip download,
//	with a clean web UI. Single static binary, Go stdlib only.
//
//	Endpoints:
//	  GET  /<path>/             browse a folder (breadcrumbs, dirs-first, filter, select)
//	  GET  /<path>/?zip         download a whole folder as a streamed .zip
//	  GET  /<path>/?json        machine-readable listing {path, entries:[...]}
//	  GET  /<file>              download a file (Range-enabled; ?dl forces attachment)
//	  GET  /<file>?sha          SHA-256 of a file (text)
//	  GET  /healthz             liveness + version + free space (JSON)
//	  POST /upload[?dir=<sub>]  streamed multipart upload; field "files";
//	                            a part's filename may be a RELATIVE PATH (folder upload)
//	  PUT  /<path>              raw streamed upload (curl -T); creates parent dirs
//	  POST /zip                 stream a zip of selected paths[] (multi-select download)
//	  POST /mkdir               make a directory   (form: path)
//	  POST /rename              rename / move       (form: from, to)
//	  POST /delete              delete file/dir     (form: path, repeatable)
//
//	Safety (always on):
//	  * every path is confined to -dir (lexical .. collapse + realpath prefix check);
//	    folder-upload relative paths and zip walks can't escape the served root
//	  * uploads are written to a temp file and atomically renamed into place, so a
//	    half-transfer is never listed or served
//	  * disk-space guard: writes are refused when free space would drop below -minfree
//	  * -readonly disables every write path (upload/PUT/mkdir/rename/delete)
//	  NOTE: there is still NO authentication or TLS — anyone who can reach the port
//	  can read and (unless -readonly) write. Auth + TLS are the next milestone.
//
//	Uploads stream via MultipartReader/io.Copy, so a multi-GB file never buffers in
//	RAM. Zips are streamed with archive/zip (method Store = fast, low CPU on a Pi).
//
//	Bind:
//	  -bind ::          all interfaces, IPv4 + IPv6 (dual-stack on Linux) -- default
//	  -bind 0.0.0.0     all IPv4 interfaces only
//	  -bind 192.168.x.x a single address
//
//	Build (on the Pi):        go build -o updrop updrop.go
//	Cross-compile from x86:   GOOS=linux GOARCH=arm64 go build -o updrop updrop.go   # Pi 3/4/5, 64-bit OS
//	                          GOOS=linux GOARCH=arm GOARM=7 go build -o updrop updrop.go  # 32-bit OS / Zero 2 W
//	Run:                      ./updrop -port 8000 -dir /srv/updrop -bind ::
//
//	curl:  upload   curl -F 'files=@file.bin' http://<host>/upload
//	       raw put  curl -T ./file.bin http://<host>/path/file.bin
//	       folder   curl -o out.zip 'http://<host>/some/dir/?zip'
//	       listing  curl 'http://<host>/?json'
//
//	Changelog:
//	  v0.2  folders end to end: subfolder browse (breadcrumbs/dirs-first/filter/select),
//	        folder upload (webkitdirectory + drag-drop tree), streamed zip download
//	        (whole dir + multi-select), delete/rename/mkdir, GET ?json, raw PUT, /healthz;
//	        path-traversal/zip-slip confinement, atomic writes, disk-space guard, -readonly
//	  v0.1  initial streaming upload server + web UI
//
// =============================================================================
package main

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"html"
	"io"
	"io/fs"
	"log"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const version = "v0.2"

var (
	uploadDir string
	readOnly  bool
	overwrite bool
	maxUpload int64 // bytes per file; 0 = unlimited
	minFree   int64 // bytes; refuse writes when free space would drop below this
)

var (
	errPathEscape = errors.New("path escapes the served directory")
	errNoSpace    = errors.New("insufficient disk space")
	errTooLarge   = errors.New("upload exceeds max size")
)

// ---- path safety -----------------------------------------------------------

// resolveWithin cleans rel against base and guarantees the result stays inside
// base. It collapses ".." lexically (so it can never point above base) and, as
// defense in depth, resolves symlinks and checks the real path is still under
// base — this stops a symlink planted inside the tree from escaping it.
func resolveWithin(base, rel string) (string, error) {
	rel = strings.ReplaceAll(rel, "\\", "/")
	clean := path.Clean("/" + strings.TrimLeft(rel, "/")) // rooted => ".." can't escape
	abs := filepath.Join(base, filepath.FromSlash(clean))

	check := abs
	if resolved, err := filepath.EvalSymlinks(abs); err == nil {
		check = resolved
	} else if errors.Is(err, os.ErrNotExist) {
		// target may not exist yet (upload/mkdir): validate the nearest existing parent
		if resolved, perr := filepath.EvalSymlinks(filepath.Dir(abs)); perr == nil {
			check = filepath.Join(resolved, filepath.Base(abs))
		}
	} else {
		return "", err
	}
	if check != base && !strings.HasPrefix(check, base+string(os.PathSeparator)) {
		return "", errPathEscape
	}
	return abs, nil
}

func freeBytes(dir string) (int64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil {
		return 0, err
	}
	return int64(st.Bavail) * int64(st.Bsize), nil
}

func isNoSpace(err error) bool { return errors.Is(err, syscall.ENOSPC) }

// uniqueName returns p if free, else inserts " (n)" before the extension.
func uniqueName(p string) string {
	if _, err := os.Lstat(p); errors.Is(err, os.ErrNotExist) {
		return p
	}
	ext := filepath.Ext(p)
	stem := strings.TrimSuffix(p, ext)
	for i := 1; ; i++ {
		cand := fmt.Sprintf("%s (%d)%s", stem, i, ext)
		if _, err := os.Lstat(cand); errors.Is(err, os.ErrNotExist) {
			return cand
		}
	}
}

// saveStream writes src to an absolute target atomically (temp + rename),
// enforcing the disk guard and max-size cap, and returns bytes + sha-256.
func saveStream(target string, src io.Reader) (int64, string, error) {
	dir := filepath.Dir(target)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return 0, "", err
	}
	if minFree > 0 {
		if fb, err := freeBytes(dir); err == nil && fb < minFree {
			return 0, "", errNoSpace
		}
	}
	tmp, err := os.CreateTemp(dir, ".updrop-*.part")
	if err != nil {
		return 0, "", err
	}
	tmpName := tmp.Name()
	h := sha256.New()
	mw := io.MultiWriter(tmp, h)

	var written int64
	buf := make([]byte, 1<<20)
	var lastCheck int64
	for {
		n, rerr := src.Read(buf)
		if n > 0 {
			if maxUpload > 0 && written+int64(n) > maxUpload {
				tmp.Close()
				os.Remove(tmpName)
				return 0, "", errTooLarge
			}
			if _, werr := mw.Write(buf[:n]); werr != nil {
				tmp.Close()
				os.Remove(tmpName)
				if isNoSpace(werr) {
					return 0, "", errNoSpace
				}
				return 0, "", werr
			}
			written += int64(n)
			if minFree > 0 && written-lastCheck >= 64<<20 { // re-check every 64 MiB
				lastCheck = written
				if fb, err := freeBytes(dir); err == nil && fb < minFree {
					tmp.Close()
					os.Remove(tmpName)
					return 0, "", errNoSpace
				}
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			tmp.Close()
			os.Remove(tmpName)
			return 0, "", rerr
		}
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return 0, "", err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return 0, "", err
	}
	final := target
	if !overwrite {
		final = uniqueName(target)
	}
	if err := os.Rename(tmpName, final); err != nil {
		os.Remove(tmpName)
		return 0, "", err
	}
	return written, hex.EncodeToString(h.Sum(nil)), nil
}

func writeErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errPathEscape):
		http.Error(w, "path not allowed", http.StatusForbidden)
	case errors.Is(err, errNoSpace):
		http.Error(w, "insufficient disk space", http.StatusInsufficientStorage)
	case errors.Is(err, errTooLarge):
		http.Error(w, "upload too large", http.StatusRequestEntityTooLarge)
	default:
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func wantsJSON(r *http.Request) bool {
	return strings.Contains(r.Header.Get("Accept"), "application/json")
}

// ---- helpers ---------------------------------------------------------------

func humanSize(n int64) string {
	if n < 1024 {
		return fmt.Sprintf("%d B", n)
	}
	units := "KMGTP"
	f := float64(n)
	i := -1
	for f >= 1024 && i < len(units)-1 {
		f /= 1024
		i++
	}
	return fmt.Sprintf("%.1f %ciB", f, units[i])
}

// hrefFor URL-escapes each path segment and joins with "/".
func hrefFor(rel string) string {
	parts := strings.Split(rel, "/")
	for i, p := range parts {
		parts[i] = url.PathEscape(p)
	}
	return strings.Join(parts, "/")
}

// ---- UI --------------------------------------------------------------------

const cssBlock = `
:root{--bg:#f6f7f9;--card:#fff;--fg:#1a1d21;--mut:#6b7280;--line:#e5e7eb;--accent:#2563eb;--hot:#eff6ff;--err:#dc2626}
@media (prefers-color-scheme:dark){:root{--bg:#0f1115;--card:#171a21;--fg:#e6e8eb;--mut:#9aa2ad;--line:#252a33;--accent:#3b82f6;--hot:#16223b;--err:#f87171}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
.wrap{max-width:900px;margin:0 auto;padding:32px 20px}
header{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap;margin-bottom:8px}
header h1{font-size:20px;margin:0;font-weight:650;letter-spacing:-.01em}
header .sub{color:var(--mut);font-size:13px}
.crumbs{font-size:13px;color:var(--mut);margin:6px 0 16px;word-break:break-all}
.crumbs a{color:var(--accent);text-decoration:none}
.crumbs a:hover{text-decoration:underline}
.zone{display:block;width:100%;padding:26px 20px;text-align:center;border:2px dashed var(--line);border-radius:12px;background:var(--card);cursor:pointer;transition:border-color .15s,background .15s}
.zone.hot{border-color:var(--accent);background:var(--hot)}
.zone .big{font-size:15px;font-weight:550}
.zone .small{color:var(--mut);font-size:13px;margin-top:4px}
#barwrap{display:none;height:6px;background:var(--line);border-radius:6px;margin-top:16px;overflow:hidden}
#bar{height:100%;width:0;background:var(--accent);transition:width .1s}
.err{color:var(--err);font-size:13px;margin-top:10px;min-height:1em;text-align:center}
.bar2{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:14px 0}
.bar2 input[type=search]{flex:1;min-width:150px;padding:.45rem .6rem;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--fg);font-size:14px}
.btn{padding:.45rem .8rem;font-size:13px;border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:8px;cursor:pointer;text-decoration:none;display:inline-block}
.btn:hover{border-color:var(--accent);color:var(--accent)}
.btn.primary{background:var(--accent);border-color:var(--accent);color:#fff}
.btn:disabled{opacity:.45;cursor:not-allowed}
table{width:100%;border-collapse:collapse;margin-top:12px}
th,td{text-align:left;padding:10px 12px;border-bottom:1px solid var(--line)}
th{color:var(--mut);font-weight:550;font-size:12px;text-transform:uppercase;letter-spacing:.04em}
th.sortable{cursor:pointer;user-select:none}
td a.name{color:var(--accent);text-decoration:none;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px;word-break:break-all}
td a.name:hover{text-decoration:underline}
tbody tr:hover td{background:var(--hot)}
.num{text-align:right;color:var(--mut);white-space:nowrap;font-variant-numeric:tabular-nums}
.mut{color:var(--mut);white-space:nowrap}
.dir a.name{font-weight:650}
.g{color:var(--mut);margin-right:6px}
.ck{width:16px;height:16px;vertical-align:middle}
.ckcol{width:34px}
td.act{white-space:nowrap}
td.act a{margin-right:12px;font-size:12px;color:var(--mut);text-decoration:none}
td.act a:hover{color:var(--accent)}
.empty{text-align:center;color:var(--mut);padding:28px}
footer{margin-top:26px;color:var(--mut);font-size:12px;text-align:center}
`

// jsBlock: raw string — MUST contain no backticks (uses '+' concatenation, no template literals).
const jsBlock = `
(function(){
  var CWD=window.__CWD, RO=window.__RO;
  function api(p){ return '/'+ (CWD? CWD.split('/').map(encodeURIComponent).join('/')+'/' : '') + p; }
  function child(name){ return CWD ? CWD+'/'+name : name; }
  var err=document.getElementById('err');
  function fail(m){ if(err){ err.textContent=m; } setTimeout(function(){ if(err) err.textContent=''; },6000); }

  // ---------- upload (files + folders + drag tree) ----------
  var zone=document.getElementById('zone'), fileIn=document.getElementById('file'),
      dirIn=document.getElementById('dir'), bar=document.getElementById('bar'), wrap=document.getElementById('barwrap');
  function send(items){ // items: [{file, rel}]
    if(!items||!items.length) return;
    if(RO){ fail('server is read-only'); return; }
    var fd=new FormData();
    for(var i=0;i<items.length;i++){ fd.append('files', items[i].file, items[i].rel); }
    var x=new XMLHttpRequest();
    x.open('POST','/upload'+(CWD?('?dir='+encodeURIComponent(CWD)):''));
    x.setRequestHeader('Accept','application/json');
    x.upload.onprogress=function(e){ if(e.lengthComputable){ wrap.style.display='block'; bar.style.width=(e.loaded/e.total*100).toFixed(0)+'%'; } };
    x.onload=function(){ if(x.status>=200&&x.status<300){ location.reload(); } else { fail('Upload failed ('+x.status+'): '+x.responseText); wrap.style.display='none'; } };
    x.onerror=function(){ fail('Upload failed — connection error'); wrap.style.display='none'; };
    x.send(fd);
  }
  function fromList(list){ var a=[]; for(var i=0;i<list.length;i++){ var f=list[i]; a.push({file:f, rel:(f.webkitRelativePath||f.name)}); } return a; }
  if(fileIn) fileIn.addEventListener('change',function(){ send(fromList(fileIn.files)); });
  if(dirIn)  dirIn.addEventListener('change', function(){ send(fromList(dirIn.files)); });

  function walk(entry, prefix, out){
    return new Promise(function(res){
      if(entry.isFile){ entry.file(function(f){ out.push({file:f, rel:prefix+entry.name}); res(); }, function(){res();}); }
      else if(entry.isDirectory){
        var rd=entry.createReader(), acc=[];
        var step=function(){ rd.readEntries(function(ents){
          if(ents.length){ acc=acc.concat([].slice.call(ents)); step(); }
          else { Promise.all(acc.map(function(e){ return walk(e, prefix+entry.name+'/', out); })).then(function(){res();}); }
        }, function(){res();}); };
        step();
      } else { res(); }
    });
  }
  if(zone){
    ['dragenter','dragover'].forEach(function(ev){ zone.addEventListener(ev,function(e){ e.preventDefault(); zone.classList.add('hot'); }); });
    ['dragleave','drop'].forEach(function(ev){ zone.addEventListener(ev,function(e){ e.preventDefault(); zone.classList.remove('hot'); }); });
    zone.addEventListener('drop',function(e){
      if(RO){ fail('server is read-only'); return; }
      var dt=e.dataTransfer, items=dt.items, entries=[];
      if(items && items.length && items[0].webkitGetAsEntry){
        for(var i=0;i<items.length;i++){ var en=items[i].webkitGetAsEntry&&items[i].webkitGetAsEntry(); if(en) entries.push(en); }
        var out=[]; Promise.all(entries.map(function(en){ return walk(en,'',out); })).then(function(){ send(out); });
      } else { send(fromList(dt.files)); }
    });
  }

  // ---------- write actions ----------
  function post(pathname, body){
    return fetch(pathname,{method:'POST',headers:{'Accept':'application/json','Content-Type':'application/x-www-form-urlencoded'},body:body});
  }
  var bMkdir=document.getElementById('bMkdir');
  if(bMkdir) bMkdir.addEventListener('click',function(){
    var n=prompt('New folder name:'); if(!n) return;
    post('/mkdir', new URLSearchParams({path:child(n)}).toString()).then(function(r){ if(r.ok) location.reload(); else r.text().then(fail); });
  });

  document.addEventListener('click',function(e){
    var a=e.target.closest ? e.target.closest('a[data-act]') : null; if(!a) return;
    e.preventDefault();
    var tr=a.closest('tr'), p=tr.getAttribute('data-path'), name=tr.getAttribute('data-name');
    if(a.getAttribute('data-act')==='delete'){
      if(!confirm('Delete "'+name+'"'+(tr.getAttribute('data-dir')==='1'?' and everything in it':'')+'?')) return;
      post('/delete', new URLSearchParams({path:p}).toString()).then(function(r){ if(r.ok) location.reload(); else r.text().then(fail); });
    } else if(a.getAttribute('data-act')==='rename'){
      var nn=prompt('Rename to:', name); if(!nn||nn===name) return;
      var parent=p.split('/').slice(0,-1).join('/'); var to=parent?parent+'/'+nn:nn;
      post('/rename', new URLSearchParams({from:p,to:to}).toString()).then(function(r){ if(r.ok) location.reload(); else r.text().then(fail); });
    }
  });

  // ---------- selection ----------
  function selected(){ return [].slice.call(document.querySelectorAll('.row:checked')).map(function(c){return c.value;}); }
  function refreshSel(){
    var n=selected().length, z=document.getElementById('bZipSel'), d=document.getElementById('bDelSel'), info=document.getElementById('selinfo');
    if(z) z.disabled=!n; if(d) d.disabled=!n; if(info) info.textContent=n?(n+' selected'):'';
  }
  var all=document.getElementById('all');
  if(all) all.addEventListener('change',function(){ [].slice.call(document.querySelectorAll('.row')).forEach(function(c){ c.checked=all.checked; }); refreshSel(); });
  document.addEventListener('change',function(e){ if(e.target.classList&&e.target.classList.contains('row')) refreshSel(); });
  var bZip=document.getElementById('bZipSel');
  if(bZip) bZip.addEventListener('click',function(){
    var s=selected(); if(!s.length) return;
    var f=document.createElement('form'); f.method='POST'; f.action='/zip'; f.style.display='none';
    s.forEach(function(p){ var i=document.createElement('input'); i.type='hidden'; i.name='paths'; i.value=p; f.appendChild(i); });
    document.body.appendChild(f); f.submit(); setTimeout(function(){ f.remove(); },1000);
  });
  var bDel=document.getElementById('bDelSel');
  if(bDel) bDel.addEventListener('click',function(){
    var s=selected(); if(!s.length) return;
    if(!confirm('Delete '+s.length+' selected item(s)?')) return;
    var body=new URLSearchParams(); s.forEach(function(p){ body.append('path',p); });
    post('/delete', body.toString()).then(function(r){ if(r.ok) location.reload(); else r.text().then(fail); });
  });

  // ---------- filter + sort ----------
  var filter=document.getElementById('filter');
  if(filter) filter.addEventListener('input',function(){
    var q=filter.value.toLowerCase();
    [].slice.call(document.querySelectorAll('tbody tr')).forEach(function(tr){
      var n=(tr.getAttribute('data-name')||'').toLowerCase();
      tr.style.display = (!q || n.indexOf(q)>=0) ? '' : 'none';
    });
  });
  [].slice.call(document.querySelectorAll('th.sortable')).forEach(function(th){
    th.addEventListener('click',function(){
      var key=th.getAttribute('data-key'), tb=document.querySelector('tbody');
      var rows=[].slice.call(tb.querySelectorAll('tr')).filter(function(r){return r.getAttribute('data-name');});
      var asc=th.getAttribute('data-asc')!=='1'; th.setAttribute('data-asc',asc?'1':'0');
      rows.sort(function(a,b){
        var av=a.getAttribute('data-'+key), bv=b.getAttribute('data-'+key);
        if(key==='size'||key==='mtime'){ av=parseFloat(av)||0; bv=parseFloat(bv)||0; return asc?av-bv:bv-av; }
        return asc? String(av).localeCompare(bv) : String(bv).localeCompare(av);
      });
      rows.forEach(function(r){ tb.appendChild(r); });
    });
  });
})();
`

type ent struct {
	name    string
	relPath string
	isDir   bool
	size    int64
	mtime   time.Time
}

func renderIndex(w http.ResponseWriter, relDir, absDir string) {
	des, _ := os.ReadDir(absDir)
	var dirs, files []ent
	for _, de := range des {
		info, err := de.Info()
		if err != nil {
			continue
		}
		rp := de.Name()
		if relDir != "" {
			rp = relDir + "/" + de.Name()
		}
		e := ent{de.Name(), rp, de.IsDir(), info.Size(), info.ModTime()}
		if e.isDir {
			dirs = append(dirs, e)
		} else {
			files = append(files, e)
		}
	}
	sort.Slice(dirs, func(i, j int) bool { return strings.ToLower(dirs[i].name) < strings.ToLower(dirs[j].name) })
	sort.Slice(files, func(i, j int) bool { return files[i].mtime.After(files[j].mtime) })

	var b strings.Builder
	b.WriteString(`<!doctype html><html lang="en"><head><meta charset="utf-8">`)
	b.WriteString(`<meta name="viewport" content="width=device-width, initial-scale=1"><title>Yatagarasu</title><style>`)
	b.WriteString(cssBlock)
	b.WriteString(`</style></head><body><div class="wrap">`)

	// header + breadcrumbs
	fmt.Fprintf(&b, `<header><h1>Yatagarasu</h1><span class="sub">%d folder(s), %d file(s)</span></header>`, len(dirs), len(files))
	b.WriteString(`<div class="crumbs"><a href="/">home</a>`)
	if relDir != "" {
		cum := ""
		for _, seg := range strings.Split(relDir, "/") {
			if cum == "" {
				cum = seg
			} else {
				cum = cum + "/" + seg
			}
			fmt.Fprintf(&b, ` / <a href="/%s/">%s</a>`, hrefFor(cum), html.EscapeString(seg))
		}
	}
	b.WriteString(`</div>`)

	// upload zone (hidden in read-only)
	if !readOnly {
		b.WriteString(`<label id="zone" class="zone"><div class="big">Drop files or folders here</div>`)
		b.WriteString(`<div class="small">or use the buttons below &mdash; whole folders keep their structure</div>`)
		b.WriteString(`<input id="file" type="file" multiple hidden><input id="dir" type="file" webkitdirectory hidden>`)
		b.WriteString(`<div id="barwrap"><div id="bar"></div></div></label><div id="err" class="err"></div>`)
	}

	// toolbar
	b.WriteString(`<div class="bar2">`)
	if !readOnly {
		b.WriteString(`<button class="btn" type="button" onclick="document.getElementById('file').click()">Upload files</button>`)
		b.WriteString(`<button class="btn" type="button" onclick="document.getElementById('dir').click()">Upload folder</button>`)
		b.WriteString(`<button class="btn" id="bMkdir" type="button">New folder</button>`)
	}
	zipHref := "/?zip"
	if relDir != "" {
		zipHref = "/" + hrefFor(relDir) + "/?zip"
	}
	fmt.Fprintf(&b, `<a class="btn" href="%s">Download folder (zip)</a>`, zipHref)
	b.WriteString(`<input id="filter" type="search" placeholder="Filter this folder…"></div>`)

	// selection actions
	b.WriteString(`<div class="bar2"><button class="btn" id="bZipSel" type="button" disabled>Download selected (zip)</button>`)
	if !readOnly {
		b.WriteString(`<button class="btn" id="bDelSel" type="button" disabled>Delete selected</button>`)
	}
	b.WriteString(`<span id="selinfo" class="sub"></span></div>`)

	// table
	b.WriteString(`<table><thead><tr><th class="ckcol"><input type="checkbox" id="all" class="ck"></th>`)
	b.WriteString(`<th class="sortable" data-key="name">Name</th><th class="num sortable" data-key="size">Size</th>`)
	b.WriteString(`<th class="mut sortable" data-key="mtime">Modified</th><th class="mut">Actions</th></tr></thead><tbody>`)

	if len(dirs)+len(files) == 0 {
		b.WriteString(`<tr><td colspan="5" class="empty">Empty &mdash; drop something above.</td></tr>`)
	}
	rowActs := func(e ent) string {
		var s strings.Builder
		if e.isDir {
			fmt.Fprintf(&s, `<a href="/%s/?zip">zip</a>`, hrefFor(e.relPath))
		} else {
			fmt.Fprintf(&s, `<a href="/%s?dl">download</a>`, hrefFor(e.relPath))
		}
		if !readOnly {
			s.WriteString(`<a href="#" data-act="rename">rename</a><a href="#" data-act="delete">delete</a>`)
		}
		return s.String()
	}
	for _, e := range dirs {
		fmt.Fprintf(&b, `<tr class="dir" data-name="%s" data-path="%s" data-dir="1" data-size="-1" data-mtime="%d">`,
			html.EscapeString(e.name), html.EscapeString(e.relPath), e.mtime.Unix())
		fmt.Fprintf(&b, `<td><input type="checkbox" class="ck row" value="%s"></td>`, html.EscapeString(e.relPath))
		fmt.Fprintf(&b, `<td><span class="g">&#9656;</span><a class="name" href="/%s/">%s/</a></td>`, hrefFor(e.relPath), html.EscapeString(e.name))
		fmt.Fprintf(&b, `<td class="num">&mdash;</td><td class="mut">%s</td><td class="act">%s</td></tr>`,
			e.mtime.Format("2006-01-02 15:04"), rowActs(e))
	}
	for _, e := range files {
		fmt.Fprintf(&b, `<tr data-name="%s" data-path="%s" data-dir="0" data-size="%d" data-mtime="%d">`,
			html.EscapeString(e.name), html.EscapeString(e.relPath), e.size, e.mtime.Unix())
		fmt.Fprintf(&b, `<td><input type="checkbox" class="ck row" value="%s"></td>`, html.EscapeString(e.relPath))
		fmt.Fprintf(&b, `<td><a class="name" href="/%s" download>%s</a></td>`, hrefFor(e.relPath), html.EscapeString(e.name))
		fmt.Fprintf(&b, `<td class="num">%s</td><td class="mut">%s</td><td class="act">%s</td></tr>`,
			humanSize(e.size), e.mtime.Format("2006-01-02 15:04"), rowActs(e))
	}
	b.WriteString(`</tbody></table>`)

	// footer
	free := ""
	if fb, err := freeBytes(absDir); err == nil {
		free = " &middot; free: " + humanSize(fb)
	}
	mode := ""
	if readOnly {
		mode = " &middot; read-only"
	}
	fmt.Fprintf(&b, `<footer>Yatagarasu %s%s%s &middot; served over your Pi access point</footer>`, version, free, mode)

	// inject CWD/RO then JS
	cwdJSON, _ := json.Marshal(relDir)
	fmt.Fprintf(&b, `<script>window.__CWD=%s;window.__RO=%t;</script><script>`, string(cwdJSON), readOnly)
	b.WriteString(jsBlock)
	b.WriteString(`</script></div></body></html>`)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	io.WriteString(w, b.String())
}

// ---- zip -------------------------------------------------------------------

func addToZip(zw *zip.Writer, root, base string) error {
	return filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // skip unreadable entries rather than abort the whole archive
		}
		if d.Type()&fs.ModeSymlink != 0 {
			return nil // never follow symlinks (escape + loop protection)
		}
		rel, rerr := filepath.Rel(base, p)
		if rerr != nil {
			return nil
		}
		rel = filepath.ToSlash(rel)
		if d.IsDir() {
			if rel == "." {
				return nil
			}
			_, e := zw.CreateHeader(&zip.FileHeader{Name: rel + "/", Method: zip.Store})
			return e
		}
		info, e := d.Info()
		if e != nil {
			return nil
		}
		fh, e := zip.FileInfoHeader(info)
		if e != nil {
			return nil
		}
		fh.Name = rel
		fh.Method = zip.Store // fast + low CPU on a Pi; it's a transfer, not archival
		wtr, e := zw.CreateHeader(fh)
		if e != nil {
			return e
		}
		f, e := os.Open(p)
		if e != nil {
			return nil
		}
		defer f.Close()
		_, e = io.Copy(wtr, f)
		return e
	})
}

func streamZip(w http.ResponseWriter, roots []string, dlName string) {
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", "attachment; filename="+strconv.Quote(dlName))
	zw := zip.NewWriter(w)
	defer zw.Close()
	for _, root := range roots {
		if err := addToZip(zw, root, filepath.Dir(root)); err != nil {
			log.Printf("zip %s: %v", root, err)
			return // headers already sent; best effort
		}
	}
}

// ---- listing / file GET ----------------------------------------------------

func jsonList(w http.ResponseWriter, relDir, absDir string) {
	type entryJSON struct {
		Name  string `json:"name"`
		Size  int64  `json:"size"`
		Mtime string `json:"mtime"`
		Dir   bool   `json:"dir"`
		Mode  string `json:"mode"`
	}
	des, _ := os.ReadDir(absDir)
	out := struct {
		Path    string      `json:"path"`
		Entries []entryJSON `json:"entries"`
	}{Path: relDir, Entries: []entryJSON{}}
	for _, de := range des {
		info, err := de.Info()
		if err != nil {
			continue
		}
		out.Entries = append(out.Entries, entryJSON{
			de.Name(), info.Size(), info.ModTime().UTC().Format(time.RFC3339), de.IsDir(), info.Mode().String(),
		})
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(out)
}

func fileSHA(w http.ResponseWriter, abs, name string) {
	f, err := os.Open(abs)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprintf(w, "%s  %s\n", hex.EncodeToString(h.Sum(nil)), name)
}

func serveGet(w http.ResponseWriter, r *http.Request) {
	abs, err := resolveWithin(uploadDir, r.URL.Path)
	if err != nil {
		writeErr(w, err)
		return
	}
	fi, err := os.Stat(abs)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	q := r.URL.Query()
	relDir := strings.Trim(r.URL.Path, "/")
	if fi.IsDir() {
		switch {
		case q.Has("zip"):
			name := "yatagarasu-root.zip"
			if relDir != "" {
				name = filepath.Base(abs) + ".zip"
			}
			streamZip(w, []string{abs}, name)
		case q.Has("json"):
			jsonList(w, relDir, abs)
		default:
			renderIndex(w, relDir, abs)
		}
		return
	}
	// file
	if q.Has("sha") {
		fileSHA(w, abs, fi.Name())
		return
	}
	if q.Has("dl") {
		w.Header().Set("Content-Disposition", "attachment; filename="+strconv.Quote(fi.Name()))
	}
	f, err := os.Open(abs)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	defer f.Close()
	http.ServeContent(w, r, fi.Name(), fi.ModTime(), f) // Range + correct content-type
}

// ---- write handlers --------------------------------------------------------

func uploadHandler(w http.ResponseWriter, r *http.Request) {
	if readOnly {
		http.Error(w, "server is read-only", http.StatusForbidden)
		return
	}
	mr, err := r.MultipartReader()
	if err != nil {
		http.Error(w, "expected multipart/form-data: "+err.Error(), http.StatusBadRequest)
		return
	}
	dirParam := r.URL.Query().Get("dir")
	type res struct {
		Name string `json:"name"`
		Size int64  `json:"size"`
		SHA  string `json:"sha256"`
	}
	var saved []res
	for {
		part, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			http.Error(w, "read error: "+err.Error(), http.StatusBadRequest)
			return
		}
		// Go's part.FileName() strips directory info (RFC 7578 filepath.Base), which
		// would flatten folder uploads — read the raw Content-Disposition filename so
		// relative subpaths survive. resolveWithin then confines them to uploadDir.
		_, cd, _ := mime.ParseMediaType(part.Header.Get("Content-Disposition"))
		raw := cd["filename"]
		if raw == "" {
			raw = part.FileName()
		}
		if raw == "" { // non-file field
			part.Close()
			continue
		}
		rel := path.Join(dirParam, strings.ReplaceAll(raw, "\\", "/"))
		target, err := resolveWithin(uploadDir, rel)
		if err != nil {
			part.Close()
			writeErr(w, err)
			return
		}
		n, sum, err := saveStream(target, part)
		part.Close()
		if err != nil {
			writeErr(w, err)
			return
		}
		saved = append(saved, res{filepath.Base(target), n, sum})
	}

	if len(saved) == 0 {
		http.Error(w, "no files received", http.StatusBadRequest)
		return
	}
	switch {
	case wantsJSON(r):
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"count": len(saved), "saved": saved})
	case strings.Contains(r.Header.Get("Accept"), "text/html"):
		http.Redirect(w, r, r.Referer(), http.StatusSeeOther)
	default:
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		for _, s := range saved {
			fmt.Fprintf(w, "%s  %12d  %s\n", s.SHA, s.Size, s.Name)
		}
	}
}

func putHandler(w http.ResponseWriter, r *http.Request) {
	if readOnly {
		http.Error(w, "server is read-only", http.StatusForbidden)
		return
	}
	target, err := resolveWithin(uploadDir, r.URL.Path)
	if err != nil {
		writeErr(w, err)
		return
	}
	if strings.HasSuffix(r.URL.Path, "/") {
		http.Error(w, "PUT target must be a file path", http.StatusBadRequest)
		return
	}
	n, sum, err := saveStream(target, r.Body)
	if err != nil {
		writeErr(w, err)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusCreated)
	fmt.Fprintf(w, "%s  %d  %s\n", sum, n, filepath.Base(target))
}

func mkdirHandler(w http.ResponseWriter, r *http.Request) {
	if readOnly {
		http.Error(w, "server is read-only", http.StatusForbidden)
		return
	}
	target, err := resolveWithin(uploadDir, r.FormValue("path"))
	if err != nil {
		writeErr(w, err)
		return
	}
	if err := os.MkdirAll(target, 0o755); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	okOrRedirect(w, r, "created")
}

func renameHandler(w http.ResponseWriter, r *http.Request) {
	if readOnly {
		http.Error(w, "server is read-only", http.StatusForbidden)
		return
	}
	from, err := resolveWithin(uploadDir, r.FormValue("from"))
	if err != nil {
		writeErr(w, err)
		return
	}
	to, err := resolveWithin(uploadDir, r.FormValue("to"))
	if err != nil {
		writeErr(w, err)
		return
	}
	if from == uploadDir {
		http.Error(w, "cannot rename the root", http.StatusBadRequest)
		return
	}
	if err := os.MkdirAll(filepath.Dir(to), 0o755); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if !overwrite {
		to = uniqueName(to)
	}
	if err := os.Rename(from, to); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	okOrRedirect(w, r, "renamed")
}

func deleteHandler(w http.ResponseWriter, r *http.Request) {
	if readOnly {
		http.Error(w, "server is read-only", http.StatusForbidden)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	paths := r.Form["path"]
	if len(paths) == 0 {
		http.Error(w, "no path", http.StatusBadRequest)
		return
	}
	var n int
	for _, p := range paths {
		abs, err := resolveWithin(uploadDir, p)
		if err != nil {
			writeErr(w, err)
			return
		}
		if abs == uploadDir {
			http.Error(w, "cannot delete the root", http.StatusBadRequest)
			return
		}
		if err := os.RemoveAll(abs); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		n++
	}
	okOrRedirect(w, r, fmt.Sprintf("deleted %d", n))
}

func zipSelectedHandler(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	paths := r.Form["paths"]
	if len(paths) == 0 {
		http.Error(w, "no paths", http.StatusBadRequest)
		return
	}
	var roots []string
	for _, p := range paths {
		abs, err := resolveWithin(uploadDir, p)
		if err != nil {
			writeErr(w, err)
			return
		}
		if _, err := os.Stat(abs); err == nil {
			roots = append(roots, abs)
		}
	}
	if len(roots) == 0 {
		http.Error(w, "nothing to zip", http.StatusNotFound)
		return
	}
	streamZip(w, roots, fmt.Sprintf("yatagarasu-selection-%s.zip", time.Now().Format("20060102-150405")))
}

func okOrRedirect(w http.ResponseWriter, r *http.Request, msg string) {
	if wantsJSON(r) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "ok", "detail": msg})
		return
	}
	if strings.Contains(r.Header.Get("Accept"), "text/html") && r.Referer() != "" {
		http.Redirect(w, r, r.Referer(), http.StatusSeeOther)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	io.WriteString(w, msg+"\n")
}

func healthz(w http.ResponseWriter, r *http.Request) {
	fb, _ := freeBytes(uploadDir)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"status": "ok", "version": version, "dir": uploadDir,
		"free_bytes": fb, "read_only": readOnly,
	})
}

// ---- routing / main --------------------------------------------------------

func handler(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet, http.MethodHead:
		if r.URL.Path == "/healthz" {
			healthz(w, r)
			return
		}
		serveGet(w, r)
	case http.MethodPost:
		switch r.URL.Path {
		case "/upload":
			uploadHandler(w, r)
		case "/zip":
			zipSelectedHandler(w, r)
		case "/mkdir":
			mkdirHandler(w, r)
		case "/rename":
			renameHandler(w, r)
		case "/delete":
			deleteHandler(w, r)
		default:
			http.Error(w, "not found", http.StatusNotFound)
		}
	case http.MethodPut:
		putHandler(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func main() {
	port := flag.Int("port", 8000, "listen port")
	bind := flag.String("bind", "::", "bind address (:: = all IPv4+IPv6, 0.0.0.0 = all IPv4, or one address)")
	dir := flag.String("dir", ".", "directory to serve and save into")
	ro := flag.Bool("readonly", false, "disable all writes (upload/PUT/mkdir/rename/delete) — browse+download only")
	ov := flag.Bool("overwrite", false, "overwrite on name collision (default: keep both, add \" (n)\" suffix)")
	maxMB := flag.Int64("maxupload", 0, "max size per uploaded file in MB (0 = unlimited)")
	minMB := flag.Int64("minfree", 16, "refuse writes when free space would drop below this many MB")
	showVer := flag.Bool("version", false, "print version and exit")
	flag.Parse()

	if *showVer {
		fmt.Println("updrop", version)
		return
	}

	abs, err := filepath.Abs(*dir)
	if err != nil {
		log.Fatal(err)
	}
	if resolved, err := filepath.EvalSymlinks(abs); err == nil {
		abs = resolved // canonicalize so the prefix check in resolveWithin is exact
	}
	uploadDir = abs
	readOnly = *ro
	overwrite = *ov
	maxUpload = *maxMB << 20
	minFree = *minMB << 20
	if err := os.MkdirAll(uploadDir, 0o755); err != nil {
		log.Fatal(err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", handler)

	addr := net.JoinHostPort(*bind, strconv.Itoa(*port)) // formats IPv6 with brackets
	srv := &http.Server{Addr: addr, Handler: mux}

	// graceful shutdown so an in-flight upload isn't truncated on stop/restart
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
		<-sig
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		srv.Shutdown(ctx)
	}()

	log.Printf("updrop %s  dir=%s  addr=%s  readonly=%t", version, uploadDir, addr, readOnly)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
