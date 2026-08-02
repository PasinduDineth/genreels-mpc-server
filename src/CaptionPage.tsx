import type {CSSProperties} from "react";
import {fitText} from "@remotion/layout-utils";
import {AbsoluteFill, useCurrentFrame, useVideoConfig} from "remotion";
import type {TikTokPage} from "@remotion/captions";
import {loadFont} from "@remotion/google-fonts/Bangers";

const {fontFamily} = loadFont();

const containerStyle: CSSProperties = {
  alignItems: "center",
  bottom: 350,
  height: 150,
  justifyContent: "center",
  top: undefined,
};

const DESIRED_FONT_SIZE = 160;
const FONT_COLOR = "#F7C615";
const STROKE_COLOR = "black";

export const CaptionPage = ({page}: {page: TikTokPage}) => {
  const frame = useCurrentFrame();
  const {fps, width} = useVideoConfig();
  const currentMs = page.startMs + (frame / fps) * 1000;
  const activeToken = page.tokens.find(
    (token) => currentMs >= token.fromMs && currentMs < token.toMs,
  );

  if (!activeToken) {
    return null;
  }

  const activeText = activeToken.text.replace(/[^\p{L}\p{N}]+/gu, '');

  if (!activeText) {
    return null;
  }
  const fittedText = fitText({
    fontFamily,
    text: activeText,
    textTransform: "uppercase",
    withinWidth: width * 0.82,
  });
  const fontSize = Math.min(DESIRED_FONT_SIZE, fittedText.fontSize);

  return (
    <AbsoluteFill style={containerStyle}>
      <div
        style={{
          color: FONT_COLOR,
          fontFamily,
          fontSize,
          lineHeight: 1,
          maxWidth: "82%",
          padding: "20px 28px",
          paintOrder: "stroke",
          textAlign: "center",
          textShadow: "0 12px 0 #000",
          textTransform: "uppercase",
          WebkitTextStroke: `14px ${STROKE_COLOR}`,
          whiteSpace: "nowrap",
        }}
      >
        {activeText}
      </div>
    </AbsoluteFill>
  );
};