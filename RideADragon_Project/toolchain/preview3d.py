"""3D preview renderer: exports parts (and optional terrain mesh) from the
simulator and renders them with WebGL2 in headless Chromium (shadow-mapped
sun light, hemisphere ambient, fog). Used for visual QA of models and maps."""
import asyncio
import json
import math
import os

import numpy as np

MATERIAL_HINTS = {
    "Neon": "emissive", "Glass": "glass", "ForceField": "glass", "Foil": "metal", "Metal": "metal",
    "DiamondPlate": "metal", "CorrodedMetal": "metal", "Ice": "glass",
}


def part_records(sim, root=None, skip_invisible=True):
    from rbx_api import part_cframe
    ws = sim.services["Workspace"]
    base = root or ws
    out = []
    for d in base.descendants():
        if not d.is_a("BasePart") or d.cls.name == "Terrain":
            continue
        if d.cls.name == "MeshPart" and any(c.cls.name == "Bone" for c in d.children):
            continue  # skinned meshes are rendered separately (meshgen/skin_render.py)
        t = d.get_prop("Transparency")
        if skip_invisible and t >= 0.98:
            continue
        cf = part_cframe(sim, d)
        size = d.get_prop("Size")
        shape = "Block"
        cn = d.cls.name
        if cn == "WedgePart":
            shape = "Wedge"
        elif cn == "CornerWedgePart":
            shape = "CornerWedge"
        elif cn in ("Part", "Seat", "SpawnLocation"):
            sh = d.props.get("Shape")
            if sh is not None:
                shape = sh.name
        sx, sy, sz = size.x, size.y, size.z
        for c in d.children:
            if c.cls.name == "SpecialMesh":
                mt = c.get_prop("MeshType").name
                sc = c.get_prop("Scale")
                if mt == "Sphere":
                    shape = "Ellipsoid"
                    sx, sy, sz = sx * sc.x, sy * sc.y, sz * sc.z
                elif mt == "Cylinder":
                    shape = "CylinderY"
                    sx, sy, sz = sx * sc.x, sy * sc.y, sz * sc.z
                elif mt == "Wedge":
                    shape = "Wedge"
                    sx, sy, sz = sx * sc.x, sy * sc.y, sz * sc.z
                elif mt == "Brick":
                    sx, sy, sz = sx * sc.x, sy * sc.y, sz * sc.z
        col = d.get_prop("Color").rgb255()
        mat = d.get_prop("Material").name
        out.append({
            "shape": shape,
            "cf": list(cf.p) + list(cf.r),
            "size": [sx, sy, sz],
            "color": list(col),
            "mat": MATERIAL_HINTS.get(mat, "plastic"),
            "t": t,
        })
    return out


def terrain_mesh(sim, x0, z0, x1, z1, step=8.0, ymin=-50, ymax=900):
    """Samples the simulated terrain surface into a height grid with colors."""
    import rbx_terrain
    st = getattr(sim, "terrain_store", None)
    if st is None or not st.ops:
        return None
    nx = int((x1 - x0) / step) + 1
    nz = int((z1 - z0) / step) + 1
    heights = np.full((nz, nx), np.nan, dtype=np.float32)
    colors = np.zeros((nz, nx, 3), dtype=np.float32)
    water = np.full((nz, nx), np.nan, dtype=np.float32)
    for iz in range(nz):
        z = z0 + iz * step
        for ix in range(nx):
            x = x0 + ix * step
            # coarse downward scan then refine
            y = ymax
            found = None
            wfound = None
            while y > ymin:
                m = st.material_at(x, y, z)
                if m is not None and m != "Air":
                    if m == "Water":
                        if wfound is None:
                            wfound = y
                    else:
                        found = (y, m)
                        break
                y -= 4
            if found:
                yy, m = found
                lo, hi = yy, yy + 4
                for _ in range(5):
                    mid = (lo + hi) / 2
                    mm = st.material_at(x, mid, z)
                    if mm is not None and mm not in ("Air", "Water"):
                        lo = mid
                    else:
                        hi = mid
                heights[iz, ix] = lo
                c = st.colors.get(m, (128, 128, 128))
                colors[iz, ix] = c
            if wfound is not None:
                water[iz, ix] = wfound + 2
    return {"x0": x0, "z0": z0, "step": step, "nx": nx, "nz": nz,
            "h": np.nan_to_num(heights, nan=ymin).tolist(), "c": colors.tolist(),
            "w": np.nan_to_num(water, nan=-9999).tolist()}


HTML = r"""
<html><body style="margin:0;background:#000"><canvas id="c"></canvas>
<script>
const W = %(w)d, H = %(h)d;
const cv = document.getElementById('c'); cv.width = W; cv.height = H;
const gl = cv.getContext('webgl2', {antialias: true, preserveDrawingBuffer: true});
const scene = %(scene)s;

function mat4mul(a,b){const r=new Float32Array(16);for(let i=0;i<4;i++)for(let j=0;j<4;j++){let s=0;for(let k=0;k<4;k++)s+=a[k*4+j]*b[i*4+k];r[i*4+j]=s;}return r;}
function persp(fov,asp,n,f){const t=1/Math.tan(fov/2);return new Float32Array([t/asp,0,0,0,0,t,0,0,0,0,(f+n)/(n-f),-1,0,0,2*f*n/(n-f),0]);}
function ortho(l,r,b,t,n,f){return new Float32Array([2/(r-l),0,0,0,0,2/(t-b),0,0,0,0,-2/(f-n),0,-(r+l)/(r-l),-(t+b)/(t-b),-(f+n)/(f-n),1]);}
function lookAt(e,c,u){let z=[e[0]-c[0],e[1]-c[1],e[2]-c[2]];let l=Math.hypot(...z);z=z.map(v=>v/l);
 let x=[u[1]*z[2]-u[2]*z[1],u[2]*z[0]-u[0]*z[2],u[0]*z[1]-u[1]*z[0]];l=Math.hypot(...x);x=x.map(v=>v/l);
 const y=[z[1]*x[2]-z[2]*x[1],z[2]*x[0]-z[0]*x[2],z[0]*x[1]-z[1]*x[0]];
 return new Float32Array([x[0],y[0],z[0],0,x[1],y[1],z[1],0,x[2],y[2],z[2],0,-(x[0]*e[0]+x[1]*e[1]+x[2]*e[2]),-(y[0]*e[0]+y[1]*e[1]+y[2]*e[2]),-(z[0]*e[0]+z[1]*e[1]+z[2]*e[2]),1]);}

// ---------------- geometry
const P=[],N=[],C=[],E=[];
function push(p,n,c,e){P.push(p[0],p[1],p[2]);N.push(n[0],n[1],n[2]);C.push(c[0],c[1],c[2],c[3]);E.push(e);}
function xf(cf,v){return [cf[3]*v[0]+cf[4]*v[1]+cf[5]*v[2]+cf[0],cf[6]*v[0]+cf[7]*v[1]+cf[8]*v[2]+cf[1],cf[9]*v[0]+cf[10]*v[1]+cf[11]*v[2]+cf[2]];}
function xn(cf,v){let r=[cf[3]*v[0]+cf[4]*v[1]+cf[5]*v[2],cf[6]*v[0]+cf[7]*v[1]+cf[8]*v[2],cf[9]*v[0]+cf[10]*v[1]+cf[11]*v[2]];const l=Math.hypot(...r)||1;return r.map(x=>x/l);}
function tri(cf,a,b,c,col,em){const ab=[b[0]-a[0],b[1]-a[1],b[2]-a[2]],ac=[c[0]-a[0],c[1]-a[1],c[2]-a[2]];
 const n=[ab[1]*ac[2]-ab[2]*ac[1],ab[2]*ac[0]-ab[0]*ac[2],ab[0]*ac[1]-ab[1]*ac[0]];const nn=xn(cf,n);
 push(xf(cf,a),nn,col,em);push(xf(cf,b),nn,col,em);push(xf(cf,c),nn,col,em);}
function quad(cf,a,b,c,d,col,em){tri(cf,a,b,c,col,em);tri(cf,a,c,d,col,em);}
function box(cf,s,col,em){const x=s[0]/2,y=s[1]/2,z=s[2]/2;
 const v=[[-x,-y,-z],[x,-y,-z],[x,y,-z],[-x,y,-z],[-x,-y,z],[x,-y,z],[x,y,z],[-x,y,z]];
 quad(cf,v[4],v[5],v[6],v[7],col,em);quad(cf,v[1],v[0],v[3],v[2],col,em);quad(cf,v[5],v[1],v[2],v[6],col,em);
 quad(cf,v[0],v[4],v[7],v[3],col,em);quad(cf,v[7],v[6],v[2],v[3],col,em);quad(cf,v[0],v[1],v[5],v[4],col,em);}
function wedge(cf,s,col,em){const x=s[0]/2,y=s[1]/2,z=s[2]/2;
 // Roblox wedge: slope from top-back (+z) to bottom-front (-z)
 const a=[-x,-y,-z],b=[x,-y,-z],c=[x,-y,z],d=[-x,-y,z],e=[x,y,z],f=[-x,y,z];
 quad(cf,a,d,c,b,col,em); quad(cf,d,f,e,c,col,em); quad(cf,a,b,e,f,col,em); tri(cf,b,c,e,col,em); tri(cf,a,f,d,col,em);}
function cornerwedge(cf,s,col,em){const x=s[0]/2,y=s[1]/2,z=s[2]/2;
 const a=[-x,-y,-z],b=[x,-y,-z],c=[x,-y,z],d=[-x,-y,z],t=[x,y,-z];
 quad(cf,a,d,c,b,col,em);tri(cf,a,b,t,col,em);tri(cf,b,c,t,col,em);tri(cf,c,d,t,col,em);tri(cf,d,a,t,col,em);}
function ellipsoid(cf,s,col,em){const seg=18,ring=12;const rx=s[0]/2,ry=s[1]/2,rz=s[2]/2;
 for(let i=0;i<ring;i++){const t0=Math.PI*i/ring,t1=Math.PI*(i+1)/ring;
  for(let j=0;j<seg;j++){const p0=2*Math.PI*j/seg,p1=2*Math.PI*(j+1)/seg;
   const pt=(t,p)=>[Math.sin(t)*Math.cos(p),Math.cos(t),Math.sin(t)*Math.sin(p)];
   const vs=[pt(t0,p0),pt(t1,p0),pt(t1,p1),pt(t0,p1)];
   const w=vs.map(v=>xf(cf,[v[0]*rx,v[1]*ry,v[2]*rz]));const ns=vs.map(v=>xn(cf,[v[0]/rx,v[1]/ry,v[2]/rz]));
   [[0,1,2],[0,2,3]].forEach(t=>t.forEach(k=>push(w[k],ns[k],col,em)));}}}
function cylinder(cf,s,col,em,axis){const seg=18;let len,r1,r2;
 if(axis==='x'){len=s[0];r1=s[1]/2;r2=s[2]/2;}else{len=s[1];r1=s[0]/2;r2=s[2]/2;}
 const P3=(a,h)=>axis==='x'?[h,Math.cos(a)*r1,Math.sin(a)*r2]:[Math.cos(a)*r1,h,Math.sin(a)*r2];
 const NN=(a)=>axis==='x'?[0,Math.cos(a)/r1,Math.sin(a)/r2]:[Math.cos(a)/r1,0,Math.sin(a)/r2];
 for(let j=0;j<seg;j++){const a0=2*Math.PI*j/seg,a1=2*Math.PI*(j+1)/seg;
  const v=[P3(a0,-len/2),P3(a0,len/2),P3(a1,len/2),P3(a1,-len/2)];const n=[NN(a0),NN(a0),NN(a1),NN(a1)];
  const w=v.map(q=>xf(cf,q));const nw=n.map(q=>xn(cf,q));[[0,1,2],[0,2,3]].forEach(t=>t.forEach(k=>push(w[k],nw[k],col,em)));
  const cap1=axis==='x'?[len/2,0,0]:[0,len/2,0], cap0=axis==='x'?[-len/2,0,0]:[0,-len/2,0];
  tri(cf,cap1,P3(a1,len/2),P3(a0,len/2),col,em); tri(cf,cap0,P3(a0,-len/2),P3(a1,-len/2),col,em);}}
for(const p of scene.parts){const c=[p.color[0]/255,p.color[1]/255,p.color[2]/255,1-(p.t||0)];const em=p.mat==='emissive'?1:(p.mat==='metal'?0.35:0);
 const cf=p.cf;switch(p.shape){case 'Ball':ellipsoid(cf,[p.size[0],p.size[0],p.size[0]],c,em);break;case 'Ellipsoid':ellipsoid(cf,p.size,c,em);break;
 case 'Cylinder':cylinder(cf,p.size,c,em,'x');break;case 'CylinderY':cylinder(cf,p.size,c,em,'y');break;case 'Wedge':wedge(cf,p.size,c,em);break;case 'CornerWedge':cornerwedge(cf,p.size,c,em);break;default:box(cf,p.size,c,em);}}
// terrain
if(scene.terrain){const T=scene.terrain;const id=[0,0,0,1,0,0,0,1,0,0,0,1];
 for(let iz=0;iz<T.nz-1;iz++)for(let ix=0;ix<T.nx-1;ix++){
  const hv=(x,z)=>T.h[z][x];const cc=(x,z)=>{const q=T.c[z][x];return [q[0]/255,q[1]/255,q[2]/255,1];};
  const X=(x)=>T.x0+x*T.step, Z=(z)=>T.z0+z*T.step;
  const a=[X(ix),hv(ix,iz),Z(iz)],b=[X(ix+1),hv(ix+1,iz),Z(iz)],c=[X(ix+1),hv(ix+1,iz+1),Z(iz+1)],d=[X(ix),hv(ix,iz+1),Z(iz+1)];
  if(a[1]<-40&&b[1]<-40&&c[1]<-40)continue;
  tri(id,a,d,c,cc(ix,iz),0);tri(id,a,c,b,cc(ix,iz),0);
  const w=T.w[iz][ix];if(w>-9000){const wc=[0.18,0.42,0.48,0.82];const s=T.step;
   tri(id,[X(ix),w,Z(iz)],[X(ix),w,Z(iz)+s],[X(ix)+s,w,Z(iz)+s],wc,0.15);tri(id,[X(ix),w,Z(iz)],[X(ix)+s,w,Z(iz)+s],[X(ix)+s,w,Z(iz)],wc,0.15);}}}
// vertex-colored meshes: {p:[...], n:[...], c:[...] (rgb 0..1 per vertex), f:[...]}
for(const m of (scene.meshes||[])){const f=m.f;for(let i=0;i<f.length;i++){const v=f[i];
 push([m.p[3*v],m.p[3*v+1],m.p[3*v+2]],[m.n[3*v],m.n[3*v+1],m.n[3*v+2]],[m.c[3*v],m.c[3*v+1],m.c[3*v+2],1],m.e||0);}}
const nverts=P.length/3;

// ---------------- shaders
function sh(type,src){const s=gl.createShader(type);gl.shaderSource(s,src);gl.compileShader(s);if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw gl.getShaderInfoLog(s);return s;}
function prog(vs,fs){const p=gl.createProgram();gl.attachShader(p,sh(gl.VERTEX_SHADER,vs));gl.attachShader(p,sh(gl.FRAGMENT_SHADER,fs));gl.linkProgram(p);return p;}
const depthP=prog(`#version 300 es
in vec3 aP;uniform mat4 uL;void main(){gl_Position=uL*vec4(aP,1.0);}`,`#version 300 es
precision highp float;out vec4 o;void main(){o=vec4(1.0);}`);
const mainP=prog(`#version 300 es
in vec3 aP;in vec3 aN;in vec4 aC;in float aE;uniform mat4 uVP;uniform mat4 uL;out vec3 vN;out vec4 vC;out vec4 vL;out vec3 vW;out float vE;
void main(){vN=aN;vC=aC;vE=aE;vW=aP;vL=uL*vec4(aP,1.0);gl_Position=uVP*vec4(aP,1.0);}`,`#version 300 es
precision highp float;in vec3 vN;in vec4 vC;in vec4 vL;in vec3 vW;in float vE;uniform sampler2D uS;uniform vec3 uSun;uniform vec3 uEye;uniform vec3 uFog;uniform float uFogD;out vec4 o;
void main(){vec3 n=normalize(vN);if(!gl_FrontFacing)n=-n;vec3 p=vL.xyz/vL.w*0.5+0.5;float sh=1.0;
 if(p.x>0.0&&p.x<1.0&&p.y>0.0&&p.y<1.0){float bias=0.0015;float s=0.0;vec2 ts=1.0/vec2(textureSize(uS,0));
  for(int x=-1;x<=1;x++)for(int y=-1;y<=1;y++){float d=texture(uS,p.xy+vec2(x,y)*ts).r;s+=(p.z-bias>d)?0.0:1.0;}sh=s/9.0;}
 float nd=max(dot(n,uSun),0.0);vec3 sky=vec3(0.62,0.70,0.82),gnd=vec3(0.34,0.31,0.26);float hemi=n.y*0.5+0.5;
 vec3 amb=mix(gnd,sky,hemi)*0.78;vec3 col=vC.rgb*(amb+vec3(1.0,0.96,0.88)*nd*sh*0.85);
 vec3 v=normalize(uEye-vW);vec3 h=normalize(uSun+v);float spec=pow(max(dot(n,h),0.0),32.0)*0.25*sh;col+=spec*(0.4+vE);
 if(vE>=0.99){col=vC.rgb*1.35;}
 float dist=length(uEye-vW);float f=1.0-exp(-dist*uFogD);col=mix(col,uFog,clamp(f,0.0,0.85));
 col=pow(col,vec3(0.95));o=vec4(col,vC.a);}`);

function buf(data,loc,size){const b=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,b);gl.bufferData(gl.ARRAY_BUFFER,new Float32Array(data),gl.STATIC_DRAW);gl.enableVertexAttribArray(loc);gl.vertexAttribPointer(loc,size,gl.FLOAT,false,0,0);}
const sun=scene.sun||[0.45,0.8,0.35];const sl=Math.hypot(...sun);const sunN=sun.map(v=>v/sl);
const ctr=scene.shadowCenter||scene.camera.target;const ext=scene.shadowExtent||60;
const lv=lookAt([ctr[0]+sunN[0]*ext*2,ctr[1]+sunN[1]*ext*2,ctr[2]+sunN[2]*ext*2],ctr,[0,1,0]);
const lp=ortho(-ext,ext,-ext,ext,0.1,ext*5);const L=mat4mul(lp,lv);
function renderAll(texImgs){
// shadow pass
const SM=4096;const tex=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,tex);gl.texImage2D(gl.TEXTURE_2D,0,gl.DEPTH_COMPONENT32F,SM,SM,0,gl.DEPTH_COMPONENT,gl.FLOAT,null);
gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.NEAREST);
gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
const fb=gl.createFramebuffer();gl.bindFramebuffer(gl.FRAMEBUFFER,fb);gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.DEPTH_ATTACHMENT,gl.TEXTURE_2D,tex,0);
const vaoS=gl.createVertexArray();gl.bindVertexArray(vaoS);gl.useProgram(depthP);buf(P,gl.getAttribLocation(depthP,'aP'),3);
gl.viewport(0,0,SM,SM);gl.enable(gl.DEPTH_TEST);gl.clear(gl.DEPTH_BUFFER_BIT);gl.uniformMatrix4fv(gl.getUniformLocation(depthP,'uL'),false,L);gl.drawArrays(gl.TRIANGLES,0,nverts);
for(const m of (scene.texMeshes||[])){const va=gl.createVertexArray();gl.bindVertexArray(va);buf(m.p,gl.getAttribLocation(depthP,'aP'),3);
 const ib=gl.createBuffer();gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER,ib);gl.bufferData(gl.ELEMENT_ARRAY_BUFFER,new Uint32Array(m.f),gl.STATIC_DRAW);
 gl.drawElements(gl.TRIANGLES,m.f.length,gl.UNSIGNED_INT,0);}
// main pass
gl.bindFramebuffer(gl.FRAMEBUFFER,null);gl.viewport(0,0,W,H);
const fog=scene.fog||[0.74,0.80,0.88];gl.clearColor(fog[0],fog[1],fog[2],1);gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);
const vao=gl.createVertexArray();gl.bindVertexArray(vao);gl.useProgram(mainP);
buf(P,gl.getAttribLocation(mainP,'aP'),3);buf(N,gl.getAttribLocation(mainP,'aN'),3);buf(C,gl.getAttribLocation(mainP,'aC'),4);buf(E,gl.getAttribLocation(mainP,'aE'),1);
const cam=scene.camera;const V=lookAt(cam.pos,cam.target,[0,1,0]);const Pm=persp(cam.fov*Math.PI/180,W/H,0.5,8000);
gl.uniformMatrix4fv(gl.getUniformLocation(mainP,'uVP'),false,mat4mul(Pm,V));gl.uniformMatrix4fv(gl.getUniformLocation(mainP,'uL'),false,L);
gl.uniform3fv(gl.getUniformLocation(mainP,'uSun'),sunN);gl.uniform3fv(gl.getUniformLocation(mainP,'uEye'),cam.pos);gl.uniform3fv(gl.getUniformLocation(mainP,'uFog'),fog);
gl.uniform1f(gl.getUniformLocation(mainP,'uFogD'),scene.fogDensity||0.0006);
gl.activeTexture(gl.TEXTURE0);gl.bindTexture(gl.TEXTURE_2D,tex);gl.uniform1i(gl.getUniformLocation(mainP,'uS'),0);
gl.enable(gl.BLEND);gl.blendFunc(gl.SRC_ALPHA,gl.ONE_MINUS_SRC_ALPHA);
gl.drawArrays(gl.TRIANGLES,0,nverts);
// sky gradient behind (drawn via clear color) - done
// textured meshes (same lighting, color from texture)
const texP=prog(`#version 300 es
in vec3 aP;in vec3 aN;in vec2 aT;in vec4 aTg;uniform mat4 uVP;uniform mat4 uL;out vec3 vN;out vec2 vT;out vec4 vL;out vec3 vW;out vec4 vTg;
void main(){vN=aN;vT=aT;vW=aP;vTg=aTg;vL=uL*vec4(aP,1.0);gl_Position=uVP*vec4(aP,1.0);}`,`#version 300 es
precision highp float;in vec3 vN;in vec2 vT;in vec4 vL;in vec3 vW;in vec4 vTg;uniform sampler2D uS;uniform sampler2D uTex;uniform sampler2D uNrm;uniform sampler2D uRgh;uniform float uHasN;uniform float uHasR;uniform vec3 uSun;uniform vec3 uEye;uniform vec3 uFog;uniform float uFogD;out vec4 o;
void main(){vec3 n=normalize(vN);if(!gl_FrontFacing)n=-n;
 if(uHasN>0.5){vec3 t=normalize(vTg.xyz-n*dot(n,vTg.xyz));vec3 b=cross(n,t)*vTg.w;vec3 nm=texture(uNrm,vT).xyz*2.0-1.0;n=normalize(t*nm.x+b*nm.y+n*nm.z);}
 float rg=0.6;if(uHasR>0.5){rg=texture(uRgh,vT).g;}
 vec3 p=vL.xyz/vL.w*0.5+0.5;float sh=1.0;
 if(p.x>0.0&&p.x<1.0&&p.y>0.0&&p.y<1.0){float bias=0.0015;float s=0.0;vec2 ts=1.0/vec2(textureSize(uS,0));
  for(int x=-1;x<=1;x++)for(int y=-1;y<=1;y++){float d=texture(uS,p.xy+vec2(x,y)*ts).r;s+=(p.z-bias>d)?0.0:1.0;}sh=s/9.0;}
 vec4 tc=texture(uTex,vT);vec3 base=pow(tc.rgb,vec3(1.0));
 float nd=max(dot(n,uSun),0.0);vec3 sky=vec3(0.62,0.70,0.82),gnd=vec3(0.34,0.31,0.26);float hemi=n.y*0.5+0.5;
 vec3 amb=mix(gnd,sky,hemi)*0.78;vec3 col=base*(amb+vec3(1.0,0.96,0.88)*nd*sh*0.85);
 vec3 v=normalize(uEye-vW);vec3 h=normalize(uSun+v);float sp=mix(140.0,6.0,rg);float spec=pow(max(dot(n,h),0.0),sp)*mix(0.9,0.05,rg)*sh;col+=spec;
 float dist=length(uEye-vW);float f=1.0-exp(-dist*uFogD);col=mix(col,uFog,clamp(f,0.0,0.85));o=vec4(pow(col,vec3(0.95)),1.0);}`);
const tms=scene.texMeshes||[];
tms.forEach((m,i)=>{
 const vao=gl.createVertexArray();gl.bindVertexArray(vao);gl.useProgram(texP);
 buf(m.p,gl.getAttribLocation(texP,'aP'),3);buf(m.n,gl.getAttribLocation(texP,'aN'),3);buf(m.uv,gl.getAttribLocation(texP,'aT'),2);
 {const lt=gl.getAttribLocation(texP,'aTg');if(m.tg){buf(m.tg,lt,4);}else{gl.disableVertexAttribArray(lt);gl.vertexAttrib4f(lt,1,0,0,1);}}
 const ib=gl.createBuffer();gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER,ib);gl.bufferData(gl.ELEMENT_ARRAY_BUFFER,new Uint32Array(m.f),gl.STATIC_DRAW);
 const tx=gl.createTexture();gl.activeTexture(gl.TEXTURE1);gl.bindTexture(gl.TEXTURE_2D,tx);
 gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,texImgs[i][0]);gl.generateMipmap(gl.TEXTURE_2D);
 gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR_MIPMAP_LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);
 function mk(img,unit){const t2=gl.createTexture();gl.activeTexture(gl.TEXTURE0+unit);gl.bindTexture(gl.TEXTURE_2D,t2);gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,img);gl.generateMipmap(gl.TEXTURE_2D);
  gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR_MIPMAP_LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);return t2;}
 const tn=texImgs[i][1]?mk(texImgs[i][1],2):null;const tr=texImgs[i][2]?mk(texImgs[i][2],3):null;
 gl.uniform1f(gl.getUniformLocation(texP,'uHasN'),tn?1.0:0.0);gl.uniform1f(gl.getUniformLocation(texP,'uHasR'),tr?1.0:0.0);
 gl.uniform1i(gl.getUniformLocation(texP,'uNrm'),2);gl.uniform1i(gl.getUniformLocation(texP,'uRgh'),3);
 gl.uniformMatrix4fv(gl.getUniformLocation(texP,'uVP'),false,mat4mul(Pm,V));gl.uniformMatrix4fv(gl.getUniformLocation(texP,'uL'),false,L);
 gl.uniform3fv(gl.getUniformLocation(texP,'uSun'),sunN);gl.uniform3fv(gl.getUniformLocation(texP,'uEye'),cam.pos);gl.uniform3fv(gl.getUniformLocation(texP,'uFog'),fog);
 gl.uniform1f(gl.getUniformLocation(texP,'uFogD'),scene.fogDensity||0.0006);
 gl.activeTexture(gl.TEXTURE0);gl.bindTexture(gl.TEXTURE_2D,tex);gl.uniform1i(gl.getUniformLocation(texP,'uS'),0);
 gl.activeTexture(gl.TEXTURE1);gl.bindTexture(gl.TEXTURE_2D,tx);gl.uniform1i(gl.getUniformLocation(texP,'uTex'),1);
 gl.disable(gl.BLEND);if(m.cull){gl.enable(gl.CULL_FACE);gl.cullFace(gl.BACK);gl.frontFace(gl.CCW);}else{gl.disable(gl.CULL_FACE);}gl.drawElements(gl.TRIANGLES,m.f.length,gl.UNSIGNED_INT,0);gl.disable(gl.CULL_FACE);});
document.title='done '+nverts;
}
// load mesh textures first, then render
(function(){const tms=scene.texMeshes||[];const imgs=tms.map(()=>[null,null,null]);let left=0;
 tms.forEach(m=>{left+=1+(m.nimg?1:0)+(m.rimg?1:0);});
 if(left===0){renderAll(imgs);return;}
 tms.forEach((m,i)=>{[m.img,m.nimg,m.rimg].forEach((url,k)=>{if(!url)return;const im=new Image();im.onload=()=>{imgs[i][k]=im;left--;if(left===0)renderAll(imgs);};im.src=url;});});})();
</script></body></html>
"""


async def _render(scene, out_path, w, h):
    from playwright.async_api import async_playwright
    html = HTML % {"w": w, "h": h, "scene": json.dumps(scene)}
    async with async_playwright() as p:
        b = await p.chromium.launch(args=["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"])
        pg = await b.new_page(viewport={"width": w, "height": h})
        if len(html) > 4_000_000:
            import tempfile
            tmp = tempfile.NamedTemporaryFile("w", suffix=".html", delete=False, dir=os.path.join(os.path.dirname(os.path.abspath(__file__)), "out"))
            tmp.write(html)
            tmp.close()
            await pg.goto("file://" + tmp.name, timeout=300000)
        else:
            await pg.set_content(html)
        for _ in range(3000):
            t = await pg.title()
            if t.startswith("done"):
                break
            await asyncio.sleep(0.1)
        else:
            raise RuntimeError("render timeout")
        await pg.locator("#c").screenshot(path=out_path)
        await b.close()
    return t


def render(parts, camera, out_path, w=1280, h=720, terrain=None, sun=None, fog=None, fog_density=None,
           shadow_center=None, shadow_extent=None):
    scene = {"parts": parts, "camera": camera}
    if terrain:
        scene["terrain"] = terrain
    if sun:
        scene["sun"] = sun
    if fog:
        scene["fog"] = fog
    if fog_density:
        scene["fogDensity"] = fog_density
    if shadow_center:
        scene["shadowCenter"] = shadow_center
    if shadow_extent:
        scene["shadowExtent"] = shadow_extent
    return asyncio.run(_render(scene, out_path, w, h))


def orbit_camera(target, dist, yaw_deg, pitch_deg, fov=50):
    y = math.radians(yaw_deg)
    p = math.radians(pitch_deg)
    pos = [target[0] + dist * math.cos(p) * math.sin(y), target[1] + dist * math.sin(p),
           target[2] + dist * math.cos(p) * math.cos(y)]
    return {"pos": pos, "target": list(target), "fov": fov}


async def _render_batch(jobs):
    from playwright.async_api import async_playwright
    async with async_playwright() as p:
        b = await p.chromium.launch(args=["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"])
        for scene, out_path, w, h in jobs:
            html = HTML % {"w": w, "h": h, "scene": json.dumps(scene)}
            pg = await b.new_page(viewport={"width": w, "height": h})
            if len(html) > 4_000_000:
                import tempfile
                tmp = tempfile.NamedTemporaryFile("w", suffix=".html", delete=False, dir=os.path.join(os.path.dirname(os.path.abspath(__file__)), "out"))
                tmp.write(html)
                tmp.close()
                await pg.goto("file://" + tmp.name, timeout=300000)
            else:
                await pg.set_content(html)
            for _ in range(6000):
                t = await pg.title()
                if t.startswith("done"):
                    break
                await asyncio.sleep(0.05)
            else:
                raise RuntimeError("render timeout")
            await pg.locator("#c").screenshot(path=out_path)
            await pg.close()
        await b.close()


def make_scene(parts, camera, terrain=None, sun=None, fog=None, fog_density=None, shadow_center=None,
               shadow_extent=None):
    scene = {"parts": parts, "camera": camera}
    for k, v in (("terrain", terrain), ("sun", sun), ("fog", fog), ("fogDensity", fog_density),
                 ("shadowCenter", shadow_center), ("shadowExtent", shadow_extent)):
        if v:
            scene[k] = v
    return scene


def render_batch(jobs):
    """jobs: list of (scene_dict, out_path, w, h) rendered in one browser session."""
    asyncio.run(_render_batch(jobs))


def contact_sheet(paths, labels, out_path, cols=3, label_h=28):
    from PIL import Image, ImageDraw, ImageFont
    ims = [Image.open(p).convert("RGB") for p in paths]
    w, h = ims[0].size
    rows = (len(ims) + cols - 1) // cols
    sheet = Image.new("RGB", (w * cols, (h + label_h) * rows), (20, 20, 24))
    dr = ImageDraw.Draw(sheet)
    try:
        from rbx_layout import FONT_DIR
        font = ImageFont.truetype(os.path.join(FONT_DIR, "Poppins-Bold.ttf"), 18)
    except Exception:
        font = ImageFont.load_default()
    for i, (im, lab) in enumerate(zip(ims, labels)):
        x, y = (i % cols) * w, (i // cols) * (h + label_h)
        sheet.paste(im, (x, y + label_h))
        dr.text((x + 8, y + 4), lab, fill=(240, 228, 200), font=font)
    sheet.save(out_path)
    return out_path


def terrain_heightfield(sim, x0, z0, x1, z1, step=6.0, ymin=-60.0):
    """Fast vectorized top-surface sampler (numpy). Replays fill ops in order:
    solids raise the surface inside their footprint, Air lowers it to the
    carve bottom, Water sets a separate water level. Exact for heightfield-like
    terrain built from upright blocks/balls/cylinders (no overhangs)."""
    st = getattr(sim, "terrain_store", None)
    if st is None or not st.ops:
        return None
    xs = np.arange(x0, x1 + 1e-6, step, dtype=np.float64)
    zs = np.arange(z0, z1 + 1e-6, step, dtype=np.float64)
    X, Z = np.meshgrid(xs, zs)
    H = np.full(X.shape, ymin, dtype=np.float64)
    M = np.full(X.shape, -1, dtype=np.int32)
    Wt = np.full(X.shape, -9999.0, dtype=np.float64)
    mats = []
    mat_id = {}

    def mid(name):
        if name not in mat_id:
            mat_id[name] = len(mats)
            mats.append(name)
        return mat_id[name]

    for op in st.ops:
        kind = op[0]
        if kind == "ball":
            c, r, mat = op[1], op[2], op[3]
            d2 = (X - c.x) ** 2 + (Z - c.z) ** 2
            inside = d2 <= r * r
            if not inside.any():
                continue
            dy = np.sqrt(np.maximum(0.0, r * r - d2))
            top = c.y + dy
            bot = c.y - dy
        elif kind in ("block", "cyl"):
            inv = op[1]
            cf = inv.inverse()
            r = cf.r
            if abs(r[4]) < 0.999:  # not upright: skip (rare in maps)
                continue
            cx, cy, cz = cf.p
            lx = r[0] * (X - cx) + r[3] * 0 + r[6] * (Z - cz)
            lz = r[2] * (X - cx) + r[5] * 0 + r[8] * (Z - cz)
            if kind == "block":
                hx, hy, hz = op[2]
                mat = op[3]
                inside = (np.abs(lx) <= hx) & (np.abs(lz) <= hz)
                top = np.full(X.shape, cy + hy)
                bot = np.full(X.shape, cy - hy)
            else:
                hh, rad = op[2]
                mat = op[3]
                inside = lx * lx + lz * lz <= rad * rad
                top = np.full(X.shape, cy + hh)
                bot = np.full(X.shape, cy - hh)
            if not inside.any():
                continue
        else:
            continue
        if mat == "Air":
            # carve: surface inside [bot, top] drops to bot
            hit = inside & (H <= top + 1e-6) & (H >= bot - 1e-6)
            H = np.where(hit, bot, H)
            Wt = np.where(inside & (Wt <= top) & (Wt >= bot), -9999.0, Wt)
        elif mat == "Water":
            Wt = np.where(inside, np.maximum(Wt, top), Wt)
        else:
            empty = H <= ymin + 1e-6
            raise_ = inside & (top > H) & ((bot <= H + 1e-6) | empty)
            H = np.where(raise_, top, H)
            M = np.where(raise_, mid(mat), M)
            # solids filling the water volume displace it
            Wt = np.where(inside & (top >= Wt), -9999.0, Wt)
    colors = np.zeros(X.shape + (3,), dtype=np.float32)
    for name, i in mat_id.items():
        c = st.colors.get(name, (128, 128, 128))
        colors[M == i] = c
    colors[M < 0] = (90, 90, 90)
    W = np.where(Wt > H, Wt, -9999.0)
    return {"x0": float(x0), "z0": float(z0), "step": float(step), "nx": int(len(xs)), "nz": int(len(zs)),
            "h": H.astype(np.float32).tolist(), "c": colors.tolist(), "w": W.astype(np.float32).tolist()}


def mesh_entry(V, F, N=None, colors=None, emissive=0.0):
    """Vertex-colored triangle mesh for scene['meshes']."""
    import numpy as _np
    V = _np.asarray(V, _np.float32)
    F = _np.asarray(F, _np.int64)
    if N is None:
        n = _np.cross(V[F[:, 1]] - V[F[:, 0]], V[F[:, 2]] - V[F[:, 0]])
        N = _np.zeros_like(V)
        for k in range(3):
            _np.add.at(N, F[:, k], n)
        N /= _np.maximum(_np.linalg.norm(N, axis=1, keepdims=True), 1e-9)
    if colors is None:
        colors = _np.full((len(V), 3), 0.6, _np.float32)
    return {"p": _np.round(V.reshape(-1), 4).tolist(), "n": _np.round(_np.asarray(N).reshape(-1), 3).tolist(),
            "c": _np.round(_np.asarray(colors, _np.float32).reshape(-1), 3).tolist(), "f": F.reshape(-1).tolist(),
            "e": emissive}


def texmesh_entry(V, F, N, UV, image, normal_image=None, rough_image=None, tangents=None, cull=False):
    """Textured mesh for scene['texMeshes']; images are PIL images. Optional
    tangent-space normal map (needs tangents xyzw) and roughness (G channel)."""
    import base64
    import io as _io
    import numpy as _np

    def url_of(im):
        buf = _io.BytesIO()
        im.save(buf, format="PNG")
        return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()

    uv = _np.asarray(UV, _np.float32).copy()
    out = {"p": _np.round(_np.asarray(V, _np.float32).reshape(-1), 4).tolist(),
           "n": _np.round(_np.asarray(N, _np.float32).reshape(-1), 3).tolist(),
           "uv": _np.round(uv.reshape(-1), 5).tolist(), "f": _np.asarray(F, _np.int64).reshape(-1).tolist(),
           "img": url_of(image)}
    if normal_image is not None and tangents is not None:
        out["nimg"] = url_of(normal_image)
        out["tg"] = _np.round(_np.asarray(tangents, _np.float32).reshape(-1), 4).tolist()
    if rough_image is not None:
        out["rimg"] = url_of(rough_image.convert("RGB"))
    if cull:
        out["cull"] = True  # back-face culling like Roblox MeshParts (inverted-hull outlines)
    return out
