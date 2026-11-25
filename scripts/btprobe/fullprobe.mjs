// 【已过时,结论不可信】ut_metadata 请求帧的长度前缀少算了消息 id 的 1 字节,对端会因此断连,
// 所以本脚本拿不到 metadata,与 peer 是否 choke 无关。请改用 swarmcheck.mjs,
// 说明见 dev/项目开发现状总结.md 第 0.2 节
// 完整 BT 链路原型:tracker -> peer 握手 -> ut_metadata -> piece
import http from 'node:http';
import net from 'node:net';

const B32='ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
function infoHash(magnet){
const m=/[?&]xt=urn:btih:([^&]+)/i.exec(magnet);if(!m)return null;
let v=decodeURIComponent(m[1]);
if(/^[0-9a-fA-F]{40}$/.test(v))return Buffer.from(v,'hex');
v=v.toUpperCase().replace(/=+$/,'');if(!/^[A-Z2-7]{32}$/.test(v))return null;
let bits='';for(const c of v)bits+=B32.indexOf(c).toString(2).padStart(5,'0');
const b=Buffer.alloc(20);for(let i=0;i<20;i++)b[i]=parseInt(bits.slice(i*8,i*8+8),2);return b;
}
const pct=b=>{let s='';for(const x of b)s+='%'+x.toString(16).padStart(2,'0');return s;};
function bdec(buf){let i=0;function d(){const c=buf[i];if(c===105){i++;let s='';while(buf[i]!==101)s+=String.fromCharCode(buf[i++]);i++;return parseInt(s,10);}if(c===108){i++;const a=[];while(buf[i]!==101)a.push(d());i++;return a;}if(c===100){i++;const o={};while(buf[i]!==101){const k=d().toString('latin1');o[k]=d();}i++;return o;}let n=0;while(buf[i]>=48&&buf[i]<=57){n=n*10+(buf[i]-48);i++;}i++;const out=buf.slice(i,i+n);i+=n;return out;}return d();}

const magnet=process.argv[2]||'magnet:?xt=urn:btih:070012114120d189066178af1e2f1c4d05d3ba95';
const hash=infoHash(magnet);
if(!hash){console.log('bad magnet');process.exit(1);}
console.log('infoHash:',hash.toString('hex'));

// 1) tracker
const peerId=Buffer.from('-ANIX01-123456789012','latin1');
function announce(url){return new Promise(res=>{
const u=new URL(url);const path=u.pathname+'?info_hash='+pct(hash)+'&peer_id='+pct(peerId)+'&port=6881&uploaded=0&downloaded=0&left=0&compact=1&event=started';
const req=http.get({host:u.hostname,port:u.port||80,path,timeout:7000},r=>{const cs=[];r.on('data',c=>cs.push(c));r.on('end',()=>{try{const d=bdec(Buffer.concat(cs));const p=d.peers;if(Buffer.isBuffer(p)){const out=[];for(let i=0;i+6<=p.length;i+=6)out.push({ip:[p[i],p[i+1],p[i+2],p[i+3]].join('.'),port:(p[i+4]<<8)|p[i+5]});res(out);}else res([]);}catch{res([]);}});});
req.on('error',()=>res([]));req.on('timeout',()=>{req.destroy();res([]);});
});}
const peerSets=await Promise.all(['http://tracker.opentrackr.org:1337/announce','http://tracker.dler.org:6969/announce'].map(announce));
const peers=peerSets.flat();
console.log('peers found:',peers.length,peers.slice(0,5));

// 2) 连 peer 握手 + 扩展握手 + ut_metadata
function connect(peer){return new Promise(res=>{
  const sock=net.createConnection({host:peer.ip,port:peer.port});
  let buf=Buffer.alloc(0);let stage=0;let extId=0;let metaSize=0;const metaPieces=[];let done=false;
  const timer=setTimeout(()=>{if(!done){done=true;sock.destroy();res(null);}},6000);
  sock.on('error',()=>{if(!done){done=true;clearTimeout(timer);res(null);}});
  sock.on('data',chunk=>{
    buf=Buffer.concat([buf,chunk]);
    if(stage===0){
      if(buf.length<68)return;
      if(buf.slice(0,20).toString('latin1')!=='BitTorrent protocol'){sock.destroy();return;}
      const reserved=buf.slice(20,28);
      if(!(reserved[5]&0x10)){sock.destroy();clearTimeout(timer);done=true;res(null);return;} // 不支持扩展
      // 发扩展握手: id=20, ext=0, bencode {m:{ut_metadata:1}}
      const extHandshake=Buffer.from('d1:md11:ut_metadatai1eee','latin1');
      const body=Buffer.concat([Buffer.from([20,0]),extHandshake]);
      const msg=Buffer.concat([Buffer.from([(body.length>>24)&255,(body.length>>16)&255,(body.length>>8)&255,body.length&255]),body]);
      sock.write(Buffer.concat([makeHandshake(),msg]));
      buf=buf.slice(68);stage=1;return;
    }
    while(stage===1&&buf.length>=4){
      const len=buf.readUInt32BE(0);if(len===0){buf=buf.slice(4);continue;}if(buf.length<4+len)return;
      const id=buf[4];const payload=buf.slice(5,4+len);buf=buf.slice(4+len);
      if(id===20){
        // 扩展消息:第一个字节是扩展 id(0=handshake)
        if(payload[0]===0){
          try{const d=bdec(payload.slice(1));const m=d.m;if(m&&m.ut_metadata){extId=m.ut_metadata;}if(d.metadata_size)metaSize=d.metadata_size;}catch{}
          // 请求 metadata piece 0
          const req=Buffer.concat([Buffer.from([extId]),Buffer.from('d8:msg_typei0e5:piecei0ee','latin1')]);
          sock.write(Buffer.concat([Buffer.from([req.length>>16&255,req.length>>8&255,req.length&255,20]),req]));
        }else if(payload[0]===extId){
          try{
            const sep=payload.indexOf(Buffer.from('ee', 'latin1'));
            // 解析 msg_type
            const d=bdec(payload.slice(1,sep+2));
            if(d.msg_type===1){metaPieces.push(payload.slice(sep+2));const total=Math.ceil(metaSize/16384);if(metaPieces.length>=total){
              const meta=Buffer.concat(metaPieces).slice(0,metaSize);const info=bdec(meta);
              const name=info.name?info.name.toString('latin1'):'?';
              const pieceLen=info['piece length'];const pieces=info.pieces;const files=info.files;
              let totalLen=info.length||0;if(files)for(const f of files)totalLen+=f.length;
              done=true;clearTimeout(timer);sock.destroy();
              res({name,pieceLen,pieces,totalLen,numPieces:pieces.length/20,files:files?files.length:1});
            }}
          }catch(e){/* ignore */}
        }
      } else if(id===5){ // unchoke -> 可以请求 piece
        // 原型阶段:只验证能拿到 metadata,拿到后已 resolve
      }
    }
  });
});
}
function makeHandshake(){
  const r=Buffer.alloc(8);r[5]|=0x10;
  return Buffer.concat([Buffer.from([19]),Buffer.from('BitTorrent protocol','latin1'),r,hash,peerId]);
}

for(const p of peers.slice(0,12)){
  const r=await connect(p);
  if(!r) console.log('  peer',p.ip+':'+p.port,'no metadata');
  if(r){console.log('METADATA OK:',JSON.stringify({name:r.name,pieceLen:r.pieceLen,totalLen:r.totalLen,numPieces:r.numPieces,files:r.files}));break;}
}
console.log('done');

