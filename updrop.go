// =============================================================================
//  updrop  -  v0.2  (Go)
//  HTTP file server with a STREAMING upload endpoint and a clean web UI.
//    GET  /            styled index: drag-drop upload + file table (browse/download)
//    POST /upload      streamed multipart -> disk (constant memory; field: files)
//    GET  /<file>      download a file (served with Range support)
//
//  Uploads stream via r.MultipartReader() + io.Copy, so a multi-GB file never
//  gets buffered in RAM. Single static binary, Go stdlib only.
//
//  Build (on the Pi):        go build -o updrop updrop_v0.2.go
//  Cross-compile from x86:   GOOS=linux GOARCH=arm64 go build -o updrop updrop_v0.2.go   # Pi 3/4/5, 64-bit OS
//                            GOOS=linux GOARCH=arm GOARM=7 go build -o updrop updrop_v0.2.go  # 32-bit OS / Zero 2 W
//  Run:                      ./updrop -port 8000 -dir /srv/updrop -bind 192.168.50.1
//
//  curl upload:  curl -F 'files=@file.bin' http://<pi-ip>:8000/upload
//
//  Changelog:
//    v0.2  professional web UI: styled index, drag-drop upload w/ progress bar,
//          sortable-by-recency file table; Post/Redirect/Get; plain-text reply for curl
//    v0.1  initial (streaming upload, minimal form + default dir listing)
// =============================================================================
package main

import (
	"flag"
	"fmt"
	"html"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

var uploadDir string

const cssBlock = `
:root{--bg:#f6f7f9;--card:#fff;--fg:#1a1d21;--mut:#6b7280;--line:#e5e7eb;--accent:#2563eb;--hot:#eff6ff;--err:#dc2626}
@media (prefers-color-scheme:dark){:root{--bg:#0f1115;--card:#171a21;--fg:#e6e8eb;--mut:#9aa2ad;--line:#252a33;--accent:#3b82f6;--hot:#16223b;--err:#f87171}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
.wrap{max-width:820px;margin:0 auto;padding:32px 20px}
header{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap;margin-bottom:20px}
header h1{font-size:20px;margin:0;font-weight:650;letter-spacing:-.01em}
header .sub{color:var(--mut);font-size:13px}
.zone{display:block;width:100%;padding:34px 20px;text-align:center;border:2px dashed var(--line);border-radius:12px;background:var(--card);cursor:pointer;transition:border-color .15s,background .15s}
.zone.hot{border-color:var(--accent);background:var(--hot)}
.zone .big{font-size:15px;font-weight:550}
.zone .small{color:var(--mut);font-size:13px;margin-top:4px}
.zone input[type=file]{margin-top:12px}
.zone button{margin-top:12px;padding:.55rem 1.1rem;font-size:14px;border:1px solid var(--accent);background:var(--accent);color:#fff;border-radius:8px;cursor:pointer}
#barwrap{display:none;height:6px;background:var(--line);border-radius:6px;margin-top:16px;overflow:hidden}
#bar{height:100%;width:0;background:var(--accent);transition:width .1s}
.err{color:var(--err);font-size:13px;margin-top:10px;min-height:1em;text-align:center}
table{width:100%;border-collapse:collapse;margin-top:24px}
th,td{text-align:left;padding:10px 12px;border-bottom:1px solid var(--line)}
th{color:var(--mut);font-weight:550;font-size:12px;text-transform:uppercase;letter-spacing:.04em}
td a{color:var(--accent);text-decoration:none;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px;word-break:break-all}
td a:hover{text-decoration:underline}
tbody tr:hover td{background:var(--hot)}
.num{text-align:right;color:var(--mut);white-space:nowrap;font-variant-numeric:tabular-nums}
.mut{color:var(--mut);white-space:nowrap}
.empty{text-align:center;color:var(--mut);padding:28px}
footer{margin-top:26px;color:var(--mut);font-size:12px;text-align:center}
`

const jsBlock = `
(function(){
  var form=document.getElementById('form'),input=document.getElementById('file'),
      btn=document.getElementById('btn'),bar=document.getElementById('bar'),
      wrap=document.getElementById('barwrap'),err=document.getElementById('err');
  input.style.display='none'; if(btn) btn.style.display='none';
  form.addEventListener('submit',function(e){e.preventDefault();});
  function up(files){
    if(!files||!files.length) return;
    err.textContent='';
    var fd=new FormData(); for(var i=0;i<files.length;i++) fd.append('files',files[i]);
    var x=new XMLHttpRequest(); x.open('POST','/upload'); x.setRequestHeader('Accept','text/plain');
    x.upload.onprogress=function(e){ if(e.lengthComputable){ wrap.style.display='block'; bar.style.width=(e.loaded/e.total*100).toFixed(0)+'%'; } };
    x.onload=function(){ if(x.status>=200&&x.status<300){ location.reload(); } else { err.textContent='Upload failed ('+x.status+')'; wrap.style.display='none'; } };
    x.onerror=function(){ err.textContent='Upload failed — connection error'; wrap.style.display='none'; };
    x.send(fd);
  }
  input.addEventListener('change',function(){ up(input.files); });
  form.addEventListener('click',function(){ input.click(); });
  ['dragenter','dragover'].forEach(function(ev){ form.addEventListener(ev,function(e){ e.preventDefault(); form.classList.add('hot'); }); });
  ['dragleave','drop'].forEach(function(ev){ form.addEventListener(ev,function(e){ e.preventDefault(); form.classList.remove('hot'); }); });
  form.addEventListener('drop',function(e){ up(e.dataTransfer.files); });
})();
`

const formBlock = `<form id="form" class="zone" action="/upload" method="post" enctype="multipart/form-data">
<div class="big">Drop files here</div>
<div class="small">or click to choose &mdash; multiple allowed</div>
<input id="file" type="file" name="files" multiple>
<button id="btn" type="submit">Upload</button>
<div id="barwrap"><div id="bar"></div></div>
</form>
<div id="err" class="err"></div>`

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

func renderIndex(w http.ResponseWriter, _ *http.Request) {
	entries, _ := os.ReadDir(uploadDir)
	var files []os.FileInfo
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if info, err := e.Info(); err == nil {
			files = append(files, info)
		}
	}
	sort.Slice(files, func(i, j int) bool { return files[i].ModTime().After(files[j].ModTime()) })

	var tbody strings.Builder
	if len(files) == 0 {
		tbody.WriteString(`<tr><td colspan="3" class="empty">No files yet &mdash; drop something above.</td></tr>`)
	} else {
		for _, f := range files {
			fmt.Fprintf(&tbody,
				`<tr><td><a href="/%s" download>%s</a></td><td class="num">%s</td><td class="mut">%s</td></tr>`,
				url.PathEscape(f.Name()), html.EscapeString(f.Name()),
				humanSize(f.Size()), f.ModTime().Format("2006-01-02 15:04"))
		}
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	io.WriteString(w, `<!doctype html><html lang="en"><head><meta charset="utf-8">`)
	io.WriteString(w, `<meta name="viewport" content="width=device-width, initial-scale=1"><title>updrop</title><style>`)
	io.WriteString(w, cssBlock)
	io.WriteString(w, `</style></head><body><div class="wrap"><header><h1>updrop</h1><span class="sub">`)
	fmt.Fprintf(w, "%d file(s) &middot; drag &amp; drop or click to upload", len(files))
	io.WriteString(w, `</span></header>`)
	io.WriteString(w, formBlock)
	io.WriteString(w, `<table><thead><tr><th>Name</th><th class="num">Size</th><th class="mut">Modified</th></tr></thead><tbody>`)
	io.WriteString(w, tbody.String())
	io.WriteString(w, `</tbody></table><footer>updrop &middot; served over your Pi access point</footer></div><script>`)
	io.WriteString(w, jsBlock)
	io.WriteString(w, `</script></body></html>`)
}

func uploadHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	mr, err := r.MultipartReader()
	if err != nil {
		http.Error(w, "expected multipart/form-data: "+err.Error(), http.StatusBadRequest)
		return
	}
	var saved []string
	for {
		part, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			http.Error(w, "read error: "+err.Error(), http.StatusBadRequest)
			return
		}
		name := filepath.Base(strings.ReplaceAll(part.FileName(), "\\", "/"))
		if name == "" || name == "." || name == ".." || name == "/" {
			part.Close()
			continue
		}
		dst, err := os.Create(filepath.Join(uploadDir, name))
		if err != nil {
			part.Close()
			http.Error(w, "create error: "+err.Error(), http.StatusInternalServerError)
			return
		}
		if _, err := io.Copy(dst, part); err != nil { // streams in ~32KB chunks
			dst.Close()
			part.Close()
			http.Error(w, "write error: "+err.Error(), http.StatusInternalServerError)
			return
		}
		dst.Close()
		part.Close()
		saved = append(saved, name)
	}

	// browser -> Post/Redirect/Get so the refreshed list shows; curl -> plain text
	if strings.Contains(r.Header.Get("Accept"), "text/html") {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	if len(saved) == 0 {
		w.WriteHeader(http.StatusBadRequest)
		io.WriteString(w, "no files received\n")
		return
	}
	fmt.Fprintf(w, "Saved %d file(s): %s\n", len(saved), strings.Join(saved, ", "))
}

func main() {
	port := flag.Int("port", 8000, "listen port")
	bind := flag.String("bind", "0.0.0.0", "bind address")
	dir := flag.String("dir", ".", "directory to serve and save into")
	flag.Parse()

	abs, err := filepath.Abs(*dir)
	if err != nil {
		log.Fatal(err)
	}
	uploadDir = abs
	if err := os.MkdirAll(uploadDir, 0o755); err != nil {
		log.Fatal(err)
	}

	fs := http.FileServer(http.Dir(uploadDir))
	mux := http.NewServeMux()
	mux.HandleFunc("/upload", uploadHandler)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			renderIndex(w, r)
			return
		}
		fs.ServeHTTP(w, r) // download individual files (safe paths + Range support)
	})

	addr := fmt.Sprintf("%s:%d", *bind, *port)
	log.Printf("updrop v0.2  dir=%s  addr=%s", uploadDir, addr)
	log.Printf("  open http://<pi-ip>:%d/", *port)
	log.Fatal(http.ListenAndServe(addr, mux))
}