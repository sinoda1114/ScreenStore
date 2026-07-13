import Foundation
import os.log

private let thumbLog = Logger(subsystem: "com.sinoda.ScreenStore", category: "thumbnail")

/// macOS のスクリーンショット Floating Thumbnail（右下に出る小窓 / `screencaptureui` daemon）が
/// pasteboard を握っている間は、他アプリが新しい貼り付け（特に Cursor / ChatGPT 等の画像貼付）を
/// 受け取れず、貼り付けに 3〜4 秒の体感遅延が出る。
///
/// ScreenStore 起動中だけ `com.apple.screencapture` ドメインの `show-thumbnail` を false に倒し、
/// 終了時に元の値（true / false / 未設定 の三状態）に正しく戻す。
///
/// 書き込みは `CFPreferencesSetAppValue` + `CFPreferencesAppSynchronize` を使う。
/// これで cfprefsd 経由で `screencaptureui` に伝播するため、`killall SystemUIServer` は不要。
enum ScreencaptureThumbnail {
    /// 対象ドメイン。
    private static let domain: CFString = "com.apple.screencapture" as CFString
    /// 対象キー。
    private static let thumbnailKey: CFString = "show-thumbnail" as CFString

    /// 元の値を退避する先 (`UserDefaults.standard`)。
    /// クラッシュ時の検出に使うので、ScreenStore 内のドメインに持つ。
    private static let backupKey = "ScreencaptureThumbnail.backup.show-thumbnail"

    /// 元の三状態を文字列として保持する。`UserDefaults` のスキーマがそのまま読めるよう、
    /// raw value は人間が見て分かる文字列にする。
    private enum Backup: String {
        case wasTrue = "true"
        case wasFalse = "false"
        case wasAbsent = "absent"

        init(forCurrent value: Bool?) {
            switch value {
            case .some(true): self = .wasTrue
            case .some(false): self = .wasFalse
            case .none: self = .wasAbsent
            }
        }
    }

    /// アプリ起動時に呼ぶ。
    ///
    /// 動作:
    /// 1. `UserDefaults.standard` のバックアップキーを覗く
    ///    - 残っていれば前回 restore できなかった残骸（クラッシュ等）とみなし、バックアップは上書きしない
    ///    - 残っていなければ、いまの `show-thumbnail` の三状態を退避する
    /// 2. `show-thumbnail = false` を書き込む
    static func suppress() {
        if let existing = readBackup() {
            thumbLog.info("suppress: backup already present from previous run (\(existing.rawValue, privacy: .public)); not overwriting")
        } else {
            let current = readCurrentValue()
            let backup = Backup(forCurrent: current)
            writeBackup(backup)
            thumbLog.info("suppress: backed up original show-thumbnail=\(backup.rawValue, privacy: .public)")
        }
        writeCurrentValue(false)
        thumbLog.info("suppress: wrote com.apple.screencapture show-thumbnail=false")
    }

    /// アプリ終了時に呼ぶ。
    ///
    /// 動作:
    /// 1. バックアップ値を読み、元の三状態に応じて
    ///    - `wasTrue`   → `show-thumbnail = true` を書く
    ///    - `wasFalse`  → `show-thumbnail = false` を書く
    ///    - `wasAbsent` → `show-thumbnail` キーを削除する（未設定状態に戻す）
    /// 2. `UserDefaults.standard` のバックアップキー自体を削除する
    static func restore() {
        let backup = readBackup()
        switch backup {
        case .some(.wasTrue):
            writeCurrentValue(true)
            thumbLog.info("restore: wrote show-thumbnail=true (original was true)")
        case .some(.wasFalse):
            writeCurrentValue(false)
            thumbLog.info("restore: wrote show-thumbnail=false (original was false)")
        case .some(.wasAbsent):
            clearCurrentValue()
            thumbLog.info("restore: cleared show-thumbnail (original was unset)")
        case .none:
            thumbLog.info("restore: no backup found; doing nothing")
        }
        UserDefaults.standard.removeObject(forKey: backupKey)
    }

    // MARK: - com.apple.screencapture 側の三状態 IO

    /// `com.apple.screencapture` の `show-thumbnail` を読む。
    ///
    /// `CFPreferencesCopyAppValue` を使うと layered defaults まで覗いて
    /// 未設定の場合でも値が返ってしまうことがあるため、三状態を正確に取りたい今回は
    /// `CFPreferencesCopyValue(currentUser, anyHost)` でユーザ側プリファレンスのみを見る。
    /// これは `defaults read com.apple.screencapture show-thumbnail` と同じ読み筋。
    private static func readCurrentValue() -> Bool? {
        let cf = CFPreferencesCopyValue(thumbnailKey, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard let cf else { return nil }
        if let number = cf as? NSNumber { return number.boolValue }
        if let string = cf as? String { return (string as NSString).boolValue }
        return nil
    }

    /// `show-thumbnail` を bool として書き、cfprefsd に sync させる。
    private static func writeCurrentValue(_ value: Bool) {
        let cfValue: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        CFPreferencesSetAppValue(thumbnailKey, cfValue, domain)
        CFPreferencesAppSynchronize(domain)
    }

    /// `show-thumbnail` キー自体を削除する（"未設定" 状態へ戻す）。
    private static func clearCurrentValue() {
        CFPreferencesSetAppValue(thumbnailKey, nil, domain)
        CFPreferencesAppSynchronize(domain)
    }

    // MARK: - UserDefaults 側のバックアップ IO

    private static func readBackup() -> Backup? {
        guard let raw = UserDefaults.standard.string(forKey: backupKey) else { return nil }
        return Backup(rawValue: raw)
    }

    private static func writeBackup(_ value: Backup) {
        UserDefaults.standard.set(value.rawValue, forKey: backupKey)
    }
}
