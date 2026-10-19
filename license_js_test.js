// 纯 JS 实现的 SHA-256 / HMAC / PBKDF2 / XOR / base64
// 用于在浏览器里生成与 Python license_core.py 完全一致的 license.dat
// 本文件仅用于本地自测，最终会嵌入 index.html

function rotr(x, n) { return ((x >>> n) | (x << (32 - n))) >>> 0; }

const SHA_K = new Uint32Array([
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
]);

function sha256(msg) {
  let h0=0x6a09e667,h1=0xbb67ae85,h2=0x3c6ef372,h3=0xa54ff53a,h4=0x510e527f,h5=0x9b05688c,h6=0x1f83d9ab,h7=0x5be0cd19;
  const l = msg.length;
  const bitLen = l * 8;
  const withOne = l + 1;
  const k = (56 - (withOne % 64) + 64) % 64;
  const total = withOne + k + 8;
  const buf = new Uint8Array(total);
  buf.set(msg, 0);
  buf[l] = 0x80;
  const dv = new DataView(buf.buffer);
  dv.setUint32(total - 8, Math.floor(bitLen / 0x100000000), false);
  dv.setUint32(total - 4, bitLen >>> 0, false);
  const w = new Uint32Array(64);
  for (let off = 0; off < total; off += 64) {
    for (let i = 0; i < 16; i++) w[i] = dv.getUint32(off + i * 4, false);
    for (let i = 16; i < 64; i++) {
      const s0 = rotr(w[i-15],7) ^ rotr(w[i-15],18) ^ (w[i-15] >>> 3);
      const s1 = rotr(w[i-2],17) ^ rotr(w[i-2],19) ^ (w[i-2] >>> 10);
      w[i] = (w[i-16] + s0 + w[i-7] + s1) | 0;
    }
    let a=h0,b=h1,c=h2,d=h3,e=h4,f=h5,g=h6,hh=h7;
    for (let i = 0; i < 64; i++) {
      const S1 = rotr(e,6) ^ rotr(e,11) ^ rotr(e,25);
      const ch = (e & f) ^ ((~e) & g);
      const t1 = (hh + S1 + ch + SHA_K[i] + w[i]) | 0;
      const S0 = rotr(a,2) ^ rotr(a,13) ^ rotr(a,22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (S0 + maj) | 0;
      hh=g; g=f; f=e; e=(d + t1) | 0; d=c; c=b; b=a; a=(t1 + t2) | 0;
    }
    h0=(h0+a)|0; h1=(h1+b)|0; h2=(h2+c)|0; h3=(h3+d)|0;
    h4=(h4+e)|0; h5=(h5+f)|0; h6=(h6+g)|0; h7=(h7+hh)|0;
  }
  const out = new Uint8Array(32);
  const odv = new DataView(out.buffer);
  const H = [h0,h1,h2,h3,h4,h5,h6,h7];
  for (let i = 0; i < 8; i++) odv.setUint32(i*4, H[i], false);
  return out;
}

function concatBytes(a, b) {
  const c = new Uint8Array(a.length + b.length);
  c.set(a, 0); c.set(b, a.length);
  return c;
}

function hmac_sha256(key, msg) {
  const B = 64;
  const keyB = new Uint8Array(B);
  if (key.length > B) { const hk = sha256(key); keyB.set(hk, 0); }
  else { keyB.set(key, 0); }
  const ikey = new Uint8Array(B), okey = new Uint8Array(B);
  for (let i = 0; i < B; i++) { ikey[i] = keyB[i] ^ 0x36; okey[i] = keyB[i] ^ 0x5c; }
  const inner = sha256(concatBytes(ikey, msg));
  return sha256(concatBytes(okey, inner));
}

function int32be(n) { return new Uint8Array([(n>>>24)&0xff,(n>>>16)&0xff,(n>>>8)&0xff,n&0xff]); }

function pbkdf2_hmac_sha256(password, salt, iterations, dkLen) {
  const hLen = 32;
  const T = new Uint8Array(dkLen);
  const blocks = Math.ceil(dkLen / hLen);
  for (let i = 1; i <= blocks; i++) {
    let U = hmac_sha256(password, concatBytes(salt, int32be(i)));
    const Tblock = U.slice();
    for (let j = 1; j < iterations; j++) {
      U = hmac_sha256(password, U);
      for (let t = 0; t < hLen; t++) Tblock[t] ^= U[t];
    }
    T.set(Tblock, (i-1) * hLen);
  }
  return T;
}

function xorBytes(a, key) {
  const out = new Uint8Array(a.length);
  for (let i = 0; i < a.length; i++) out[i] = a[i] ^ key[i % key.length];
  return out;
}

const B64C = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function b64encode(bytes) {
  let s = "";
  let i;
  for (i = 0; i + 2 < bytes.length; i += 3) {
    const n = (bytes[i]<<16) | (bytes[i+1]<<8) | bytes[i+2];
    s += B64C[(n>>18)&63] + B64C[(n>>12)&63] + B64C[(n>>6)&63] + B64C[n&63];
  }
  const rem = bytes.length - i;
  if (rem === 1) { const n = bytes[i]<<16; s += B64C[(n>>18)&63] + B64C[(n>>12)&63] + "=="; }
  else if (rem === 2) { const n = (bytes[i]<<16) | (bytes[i+1]<<8); s += B64C[(n>>18)&63] + B64C[(n>>12)&63] + B64C[(n>>6)&63] + "="; }
  return s;
}
function b64decode(str) {
  str = str.replace(/[^A-Za-z0-9+/=]/g, "");
  const out = [];
  for (let i = 0; i < str.length; ) {
    const a = Math.max(0, B64C.indexOf(str[i++]));
    const b = Math.max(0, B64C.indexOf(str[i++]));
    const c = Math.max(0, B64C.indexOf(str[i++]));
    const d = Math.max(0, B64C.indexOf(str[i++]));
    const n = (a<<18) | (b<<12) | (c<<6) | d;
    out.push((n>>16) & 0xff);
    if (str[i-2] !== '=') out.push((n>>8) & 0xff);
    if (str[i-1] !== '=') out.push(n & 0xff);
  }
  return new Uint8Array(out);
}

function utf8encode(str) {
  const out = [];
  for (let i = 0; i < str.length; i++) {
    const c = str.charCodeAt(i);
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c>>6), 0x80 | (c & 0x3f));
    else out.push(0xe0 | (c>>12), 0x80 | ((c>>6) & 0x3f), 0x80 | (c & 0x3f));
  }
  return new Uint8Array(out);
}

// ---- 与 Python license_core.py 对齐的常量 ----
const AUTH_KEY_STR = "FTP-PULLER-AUTH-KEY-2026-GOLDENCIS-9f3a2c7b";
const SALT_STR = "ftp-puller-license-salt-v1";

function pad2(n) { return (n < 10 ? "0" : "") + n; }
function todayISO() {
  const d = new Date();
  return d.getFullYear() + "-" + pad2(d.getMonth()+1) + "-" + pad2(d.getDate());
}

function make_license(expire, issued) {
  if (!issued) issued = todayISO();
  // 严格模拟 Python: json.dumps({"expire":..,"issued":..}, sort_keys=True) -> 空格分隔
  const docStr = '{"expire": "' + expire + '", "issued": "' + issued + '"}';
  const doc = utf8encode(docStr);
  const key = utf8encode(AUTH_KEY_STR);
  const salt = utf8encode(SALT_STR);
  const dk = pbkdf2_hmac_sha256(key, salt, 10000, 32);
  const enc = xorBytes(doc, dk);
  const mac = hmac_sha256(dk, enc);
  return b64encode(concatBytes(enc, mac));
}

// 校验端(供 HTML "校验"功能使用)
function verify_license(blob) {
  let raw;
  try { raw = b64decode(blob); } catch (e) { return { ok:false, msg:"授权文件不是合法的 base64 编码" }; }
  if (raw.length < 33) return { ok:false, msg:"授权文件长度异常(可能被截断或篡改)" };
  const enc = raw.subarray(0, raw.length - 32);
  const mac = raw.subarray(raw.length - 32);
  const key = utf8encode(AUTH_KEY_STR);
  const salt = utf8encode(SALT_STR);
  const dk = pbkdf2_hmac_sha256(key, salt, 10000, 32);
  // 比对 HMAC
  const calc = hmac_sha256(dk, enc);
  let same = calc.length === mac.length;
  for (let i = 0; i < calc.length && same; i++) if (calc[i] !== mac[i]) same = false;
  if (!same) return { ok:false, msg:"授权文件签名校验失败(可能被篡改)" };
  const docBytes = xorBytes(enc, dk);
  let docStr = "";
  for (let i = 0; i < docBytes.length; i++) docStr += String.fromCharCode(docBytes[i]);
  let doc;
  try { doc = JSON.parse(docStr); } catch (e) { return { ok:false, msg:"授权文件解密失败(可能密钥不匹配或被破坏)" }; }
  const exp = doc.expire;
  if (!exp) return { ok:false, msg:"授权文件缺少到期字段" };
  const m = exp.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!m) return { ok:false, msg:"授权到期日期格式错误: " + exp };
  const ed = new Date(parseInt(m[1]), parseInt(m[2])-1, parseInt(m[3]));
  const today = new Date(); today.setHours(0,0,0,0); ed.setHours(0,0,0,0);
  const days = Math.round((ed - today) / 86400000);
  if (days < 0) return { ok:false, msg:"授权已过期 (到期 " + exp + ", 今天 " + todayISO() + ")" };
  return { ok:true, msg:"授权有效 (到期 " + exp + ", 剩余 " + days + " 天)" };
}

// ===== 本地自测(仅 node 运行; 浏览器中本段不执行) =====
if (typeof module !== "undefined" && require.main === module) {
  const blob = make_license("2027-12-31", "2026-10-11");
  require("fs").writeFileSync("C:/Users/LW/WorkBuddy/2026-10-10-18-58-03/_js_lic.txt", blob);
  console.log("JS blob:", blob);
  const v = verify_license(blob);
  console.log("JS verify:", v.ok, v.msg);
  const v2 = verify_license(make_license("2020-01-01", "2019-01-01"));
  console.log("JS verify expired:", v2.ok, v2.msg);
}
