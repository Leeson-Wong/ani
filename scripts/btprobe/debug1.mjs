import net from 'node:net';
const hash=Buffer.from('070012114120d189066178af1e2f1c4d05d3ba95','hex');
const peerId=Buffer.from('-ANIX01-123456789012','latin1');
const ip='185.21.217.79',port=46815;
function hs(){const r=Buffer.alloc(8);r[5]|=0x10;return Buffer.concat([Buffer.from([19]),Buffer.from('BitTorrent protocol','latin1'),r,hash,peerId]);}
const sock=net.createConnection({host:ip,port});
let sent=false;
sock.on('connect',()=>{console.log('connected to',ip,port);sock.write(hs());});
sock.on('data',d=>{
  console.log('recv',d.length,'bytes:',d.slice(0,80).toString('hex'));
  if(d.length>=68){
    console.log('pstrlen',d[0],'protocol',d.slice(1,20).toString('latin1'));
    console.log('reserved',d.slice(20,28).toString('hex'),'ext bit',!!(d[25]&0x10));
  }
  if(!sent){ // 发扩展握手
    const ext=Buffer.from('d1:md11:ut_metadatai1eee','latin1');
    const msg=Buffer.concat([Buffer.from([0,0,0,4+ext.length,20,0]),ext]);
    sock.write(msg);console.log('sent ext handshake',msg.length);sent=true;
  }
});
sock.on('error',e=>console.log('ERR',e.code||e.message));
sock.on('close',()=>{console.log('closed');process.exit(0);});
setTimeout(()=>{console.log('timeout');sock.destroy();process.exit(0);},12000);
