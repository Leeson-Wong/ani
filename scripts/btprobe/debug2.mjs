// 【已过时,结论不可信】本脚本有两处错误,得到的「被 CHOKE」是误判:
//   1. 消息 id 标反:协议里 1=UNCHOKE、5=BITFIELD,下面却把 1 打印成 CHOKE、5 打印成 UNCHOKE
//   2. 扩展握手/ut_metadata 请求的长度前缀少算了消息 id 的 1 字节,对端会因此断连
// 请改用 swarmcheck.mjs,说明见 dev/项目开发现状总结.md 第 0.2 节
import net from 'node:net';
const hash=Buffer.from('070012114120d189066178af1e2f1c4d05d3ba95','hex');
const peerId=Buffer.from('-ANIX01-123456789012','latin1');
const ip=process.argv[2]||'185.21.217.79',port=Number(process.argv[3]||46815);
function hs(){const r=Buffer.alloc(8);r[5]|=0x10;return Buffer.concat([Buffer.from([19]),Buffer.from('BitTorrent protocol','latin1'),r,hash,peerId]);}
function bdec(buf){let i=0;function d(){const c=buf[i];if(c===105){i++;let s='';while(buf[i]!==101)s+=String.fromCharCode(buf[i++]);i++;return parseInt(s,10);}if(c===108){i++;const a=[];while(buf[i]!==101)a.push(d());i++;return a;}if(c===100){i++;const o={};while(buf[i]!==101){const k=d().toString('latin1');o[k]=d();}i++;return o;}let n=0;while(buf[i]>=48&&buf[i]<=57){n=n*10+(buf[i]-48);i++;}i++;return buf.slice(i,(i+=n));}return d();}
const sock=net.createConnection({host:ip,port});
let extId=0,metaSize=0,gotHs=false,askedMeta=false,buf=Buffer.alloc(0);
sock.on('connect',()=>sock.write(hs()));
sock.on('error',e=>console.log('ERR',e.code||e.message));
sock.on('data',chunk=>{
  buf=Buffer.concat([buf,chunk]);
  if(!gotHs){ if(buf.length<68)return; console.log('handshake ok, ext bit',!!(buf[25]&0x10)); buf=buf.slice(68); gotHs=true; }
  while(buf.length>=4){
    const len=buf.readUInt32BE(0); if(len===0){buf=buf.slice(4);continue;} if(buf.length<4+len)break;
    const id=buf[4], payload=buf.slice(5,4+len); buf=buf.slice(4+len);
    if(id===20){
      const xid=payload[0];
      console.log('EXT msg, extid=',xid,'payload head=',payload.slice(1,40).toString('latin1').replace(/[^\x20-\x7e]/g,'.'));
      if(xid===0){
        try{const d=bdec(payload.slice(1));console.log('  ext handshake m=',JSON.stringify(d.m),'metadata_size=',d.metadata_size);if(d.m&&d.m.ut_metadata)extId=d.m.ut_metadata;if(d.metadata_size)metaSize=d.metadata_size;}catch(e){console.log('  decode err',e.message);}
      } else {
        console.log('  >> metadata response! len=',payload.length);
        try{const sep=payload.indexOf(Buffer.from('ee'));const d=bdec(payload.slice(1,sep+2));console.log('  msg_type=',d.msg_type,'piece=',d.piece,'total_size=',d.total_size,'dataLen=',payload.length-sep-2);}catch(e){console.log('  meta decode err',e.message);}
      }
    } else if(id===5){console.log('UNCHOKE');}
    else if(id===1){console.log('CHOKE');}
    else console.log('msg id',id,'len',len);
  }
  if(gotHs&&extId>0&&!askedMeta&&buf.length===0){
    askedMeta=true;
    const inner=Buffer.concat([Buffer.from([extId]),Buffer.from('d8:msg_typei0e5:piecei0ee','latin1')]);
    const frame=Buffer.concat([Buffer.from([(inner.length>>>24)&255,(inner.length>>>16)&255,(inner.length>>>8)&255,inner.length&255]),inner]);
    sock.write(frame);
    console.log('sent ut_metadata REQUEST, extId=',extId,'frame=',frame.toString('hex'));
    // 同时发 interested
    sock.write(Buffer.from([0,0,0,1,2]));
  }
});
setTimeout(()=>{console.log('--- timeout, gotHs=',gotHs,'extId=',extId,'metaSize=',metaSize);sock.destroy();process.exit(0);},10000);
