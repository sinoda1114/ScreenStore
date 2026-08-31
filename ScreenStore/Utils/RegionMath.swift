import Foundation
import CoreGraphics

/// 範囲指定キャプチャの座標変換ヘルパ。
///
/// 透過オーバーレイ NSWindow は対象 NSScreen の `frame` と一致するように貼られるため、
/// `mouseDown` 系で得られるウィンドウ内座標 (origin = 左下、単位 = point) は
/// そのまま「画面内座標 (左下原点)」として扱える。
///
/// SCK で取得した CGImage はピクセル単位 / 左上原点なので、ここで Y 軸反転 + scale 倍 を行う。
enum RegionMath {

    /// ドラッグ開始点と現在点から左下原点・正の幅高さの矩形を作る。
    static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    /// ウィンドウ内座標 (左下原点 / point) の矩形を、CGImage の crop 矩形 (左上原点 / pixel) に変換する。
    ///
    /// - Parameters:
    ///   - rect: NSWindow ローカル座標 (左下原点) の point 矩形
    ///   - windowSize: NSWindow の content サイズ (point)。NSScreen.frame.size と一致する想定
    ///   - backingScale: 対象 NSScreen.backingScaleFactor
    /// - Returns: CGImage 上の crop 矩形 (左上原点 / pixel)。`integral` で整数化済み
    static func pixelCropRect(
        windowLocalRect rect: CGRect,
        windowSize: CGSize,
        backingScale scale: CGFloat
    ) -> CGRect {
        let flippedY = windowSize.height - (rect.origin.y + rect.size.height)
        let topDown = CGRect(
            x: rect.origin.x,
            y: flippedY,
            width: rect.size.width,
            height: rect.size.height
        )
        return CGRect(
            x: topDown.origin.x * scale,
            y: topDown.origin.y * scale,
            width: topDown.size.width * scale,
            height: topDown.size.height * scale
        ).integral
    }

    /// AppKit の左下原点・point矩形を、ScreenCaptureKit の `sourceRect` が使う
    /// 左上原点・point矩形へ変換する。ピクセル倍率は `SCStreamConfiguration.width/height`
    /// にだけ反映し、`sourceRect` 自体には掛けない。
    static func screenCaptureKitSourceRect(
        windowLocalRect rect: CGRect,
        windowSize: CGSize
    ) -> CGRect {
        CGRect(
            x: rect.minX,
            y: windowSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// `screencapture -R` に渡すためのグローバル pixel 矩形。
    /// `CGDisplayBounds` はディスプレイごとのグローバル pixel 座標を返すため、
    /// 画面内の top-left pixel 矩形を足し込む。
    static func screencapturePixelRect(
        windowLocalRect rect: CGRect,
        windowSize: CGSize,
        backingScale scale: CGFloat,
        displayID: CGDirectDisplayID
    ) -> CGRect {
        let local = pixelCropRect(
            windowLocalRect: rect,
            windowSize: windowSize,
            backingScale: scale
        )
        let displayBounds = CGDisplayBounds(displayID)
        return CGRect(
            x: displayBounds.minX + local.minX,
            y: displayBounds.minY + local.minY,
            width: local.width,
            height: local.height
        ).integral
    }

    /// 与えられた pixel 矩形を画像の境界内にクランプする。
    /// 画面外まで広げて選択された場合や、整数化丸めで 1px はみ出た場合の保険。
    static func clamp(rect: CGRect, to imageSize: CGSize) -> CGRect {
        let x = max(0, min(rect.origin.x, imageSize.width))
        let y = max(0, min(rect.origin.y, imageSize.height))
        let maxW = max(0, imageSize.width - x)
        let maxH = max(0, imageSize.height - y)
        let w = max(0, min(rect.size.width, maxW))
        let h = max(0, min(rect.size.height, maxH))
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
