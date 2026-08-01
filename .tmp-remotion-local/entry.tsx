import React from "react";
import {AbsoluteFill, Audio, Video, Sequence, registerRoot, Composition} from "remotion";

const VIDEO1 = 'http://127.0.0.1:8123/video1';
const VIDEO2 = 'http://127.0.0.1:8123/video2';
const AUDIO = 'http://127.0.0.1:8123/audio';

const Test = () => {
  return (
    <AbsoluteFill style={{backgroundColor: '#050816'}}>
      <Sequence from={0} durationInFrames={150}>
        <AbsoluteFill>
          <Video src={VIDEO1} muted playsInline style={{width: '100%', height: '100%', objectFit: 'cover'}} />
          <AbsoluteFill style={{background: 'linear-gradient(to top, rgba(5,8,22,0.55), rgba(5,8,22,0.08) 50%, rgba(5,8,22,0.18))'}} />
        </AbsoluteFill>
      </Sequence>
      <Sequence from={150} durationInFrames={150}>
        <AbsoluteFill>
          <Video src={VIDEO2} muted playsInline style={{width: '100%', height: '100%', objectFit: 'cover'}} />
          <AbsoluteFill style={{background: 'linear-gradient(to top, rgba(5,8,22,0.55), rgba(5,8,22,0.08) 50%, rgba(5,8,22,0.18))'}} />
        </AbsoluteFill>
      </Sequence>
      <Audio src={AUDIO} volume={0.18} loop />
      <AbsoluteFill style={{justifyContent: 'flex-end', padding: '80px 64px', color: 'white', pointerEvents: 'none'}}>
        <div style={{fontSize: 56, fontWeight: 800, textShadow: '0 6px 24px rgba(0,0,0,0.45)'}}>Local Remotion Test</div>
        <div style={{fontSize: 28, marginTop: 16, opacity: 0.9}}>tt1 + tt2 + Varnished Silence</div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

const Root = () => <Composition id="LocalTest" component={Test} width={1080} height={1920} fps={30} durationInFrames={300} />;
registerRoot(Root);
