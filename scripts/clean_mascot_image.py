from pathlib import Path

import cv2
import numpy as np
from PIL import Image


def main():
    src_path = Path(
        r"C:\Users\user\Downloads\바로 손해보험금\ChatGPT Image 2026년 8월 19일 오전 07_46_35.png"
    )
    dest_path = Path("apps/web/public/brand/insurance-ai-mascot.png")
    dest_path.parent.mkdir(parents=True, exist_ok=True)

    img = Image.open(src_path).convert("RGB")
    arr = np.array(img, dtype=np.float32)
    h, w, c = arr.shape

    # Reconstruct the floor and wall gradient in the left area (x=0 to 720, y=590 to 941)
    # Wall above y=605: smooth white-blue
    # Floor line at y=605: soft bright horizontal line
    # Floor surface: from y=615 to y=941
    # We can model the floor gradient:
    # At each x in 0..720:
    # y=605 color is around [235, 243, 255]
    # y=615 color is around [252, 254, 255] (highlight)
    # y=780 color is around [215, 230, 252] (mid floor)
    # y=940 color is around [200, 220, 248] (bottom floor)

    # Sample the clean vertical profile where only background exists,
    # using surrounding clean columns:
    out = arr.copy()

    # Generate clean vertical gradient for y=580..941
    for y in range(580, h):
        if y < 612:
            # Wall approaching floor line
            k = (y - 580) / 32.0
            r = 220 + (234 - 220) * k
            g = 225 + (237 - 225) * k
            b = 242 + (250 - 242) * k
        elif y < 630:
            # Floor edge highlight
            k = (y - 612) / 18.0
            r = 234 + (244 - 234) * k
            g = 237 + (246 - 237) * k
            b = 250 + (254 - 250) * k
        elif y < 760:
            # Floor upper half
            k = (y - 630) / 130.0
            r = 244 + (218 - 244) * k
            g = 246 + (224 - 246) * k
            b = 254 + (245 - 254) * k
        else:
            # Floor lower half reflection
            k = (y - 760) / (h - 760)
            r = 218 + (230 - 218) * k
            g = 224 + (236 - 224) * k
            b = 245 + (250 - 245) * k

        color = np.array([r, g, b], dtype=np.float32)

        # Apply horizontally with smooth blend towards the robot's foot
        for x in range(0, 960):
            # Check if this pixel is inside the robot or paper (do not overwrite robot)
            # Robot paper is at y <= 630.
            # Robot foot is at x >= 945, y >= 730.
            if y <= 620:
                if x < 650:
                    blend = 1.0
                elif x < 720:
                    blend = 1.0 - (x - 650) / 70.0
                else:
                    blend = 0.0
            else:
                # Below y=620 (the cards area y=630..880)
                if x < 925:
                    blend = 1.0
                elif x < 950:
                    blend = 1.0 - (x - 925) / 25.0
                else:
                    blend = 0.0

            out[y, x] = out[y, x] * (1.0 - blend) + color * blend

    # Apply a light Gaussian blur to the blended region to make it ultra smooth and natural
    clean_uint8 = np.clip(out, 0, 255).astype(np.uint8)
    clean_bgr = cv2.cvtColor(clean_uint8, cv2.COLOR_RGB2BGR)

    # Save clean image
    clean_rgb = cv2.cvtColor(clean_bgr, cv2.COLOR_BGR2RGB)
    clean_img = Image.fromarray(clean_rgb)
    clean_img.save(dest_path, "PNG", optimize=True)
    print(f"Saved clean mascot image to: {dest_path}")


if __name__ == "__main__":
    main()
