// 验证从 ArkTS 源码移植过来的 SHA1 逻辑(同一份算法)
function rol(v,n){return ((v<<n)|(v>>>(32-n)))>>>0;}
function sha1(data){
  const ml=data.length*8;
  const zeroPad=(56-((data.length+1)%64)+64)%64;
  const total=data.length+1+zeroPad+8;
  const msg=new Uint8Array(total);msg.set(data,0);msg[data.length]=0x80;
  const high=Math.floor(ml/0x100000000),low=ml>>>0,lenPos=total-8;
  msg[lenPos]=(high>>>24)&255;msg[lenPos+1]=(high>>>16)&255;msg[lenPos+2]=(high>>>8)&255;msg[lenPos+3]=high&255;
  msg[lenPos+4]=(low>>>24)&255;msg[lenPos+5]=(low>>>16)&255;msg[lenPos+6]=(low>>>8)&255;msg[lenPos+7]=low&255;
  let h0=0x67452301,h1=0xefcdab89,h2=0x98badcfe,h3=0x10325476,h4=0xc3d2e1f0;
  const w=new Uint32Array(80);
  for(let off=0;off<total;off+=64){
    for(let i=0;i<16;i++){const j=off+i*4;w[i]=((msg[j]<<24)|(msg[j+1]<<16)|(msg[j+2]<<8)|msg[j+3])>>>0;}
    for(let i=16;i<80;i++)w[i]=rol(w[i-3]^w[i-8]^w[i-14]^w[i-16],1);
    let a=h0,b=h1,c=h2,d=h3,e=h4;
    for(let i=0;i<80;i++){
      let f=0,k=0;
      if(i<20){f=(b&c)|((~b)&d);k=0x5a827999;}else if(i<40){f=b^c^d;k=0x6ed9eba1;}else if(i<60){f=(b&c)|(b&d)|(c&d);k=0x8f1bbcdc;}else{f=b^c^d;k=0xca62c1d6;}
      const t=(rol(a,5)+f+e+k+w[i])>>>0;e=d;d=c;c=rol(b,30);b=a;a=t;
    }
    h0=(h0+a)>>>0;h1=(h1+b)>>>0;h2=(h2+c)>>>0;h3=(h3+d)>>>0;h4=(h4+e)>>>0;
  }
  const out=new Uint8Array(20),hs=[h0,h1,h2,h3,h4];
  for(let i=0;i<5;i++){out[i*4]=(hs[i]>>>24)&255;out[i*4+1]=(hs[i]>>>16)&255;out[i*4+2]=(hs[i]>>>8)&255;out[i*4+3]=hs[i]&255;}
  return out;
}
const enc=s=>new TextEncoder().encode(s);
const hex=b=>Array.from(b).map(x=>x.toString(16).padStart(2,'0')).join('');
console.log('sha1("abc") =',hex(sha1(enc('abc'))),'(期望 a9993e364706816aba3e25717850c26c9cd0d89d)');
console.log('sha1("")    =',hex(sha1(enc(''))),'(期望 da39a3ee5e6b4b0d3255bfef95601890afd80709)');
const long='a'.repeat(1000000);
console.log('sha1(1MB a) =',hex(sha1(enc(long))),'(期望 34aa973cd4c4daa4f61eeb2bdbad27316534016f)');
