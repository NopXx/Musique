import Foundation

enum L10n {
    static var lang: String {
        let s = SettingsStore.shared.string(["language"])
        return s.isEmpty ? "th" : s
    }

    static func tr(_ th: String, _ en: String) -> String {
        lang == "en" ? en : th
    }

    // MARK: - Sidebar tabs

    static var tabNotifications: String { tr("แจ้งเตือน", "Notifications") }
    static var tabHistory: String { tr("ประวัติ", "History") }

    // MARK: - Last.fm

    static var lastfmTitle: String { tr("เชื่อมต่อ Last.fm", "Connect Last.fm") }
    static var lastfmSubtitle: String { tr("ส่ง now-playing และ scrobble เพลงไปที่ Last.fm", "Send now-playing and scrobble tracks to Last.fm") }
    static var lastfmConnected: String { tr("เชื่อมต่อแล้วเป็น", "Connected as") }
    static var lastfmEnableScrobbling: String { tr("เปิดใช้งาน Scrobbling", "Enable Scrobbling") }
    static var lastfmDisconnect: String { tr("ตัดการเชื่อมต่อ", "Disconnect") }
    static var lastfmNotConnected: String { tr("ยังไม่ได้เชื่อมต่อ", "Not connected") }
    static var lastfmCancel: String { tr("ยกเลิก", "Cancel") }
    static var lastfmWaiting: String { tr("กำลังรอการอนุมัติ…", "Waiting for approval…") }
    static var lastfmGetApiKey: String { tr("ขอ API key ฟรี →", "Get a free API key →") }
    static var lastfmNeedKeys: String { tr("ต้องใส่ API Key และ Secret ก่อน", "Enter API Key and Secret first") }
    static var lastfmTokenFail: String { tr("ขอ token ไม่สำเร็จ", "Failed to get token") }
    static func lastfmConnectedAs(_ name: String) -> String { tr("เชื่อมต่อกับ Last.fm เป็น \(name)", "Connected to Last.fm as \(name)") }
    static var lastfmDisconnected: String { tr("ตัดการเชื่อมต่อแล้ว", "Disconnected") }
    static var lastfmTimeout: String { tr("หมดเวลารอ — ลองอีกครั้ง", "Timed out — try again") }

    // MARK: - Scrobble

    static var scrobbleTitle: String { tr("กฎการ Scrobble", "Scrobble Rules") }
    static var scrobbleSubtitle: String { tr("เกณฑ์ที่ใช้ตัดสินว่าเพลงควรถูก scrobble หรือไม่", "Criteria to decide whether a track should be scrobbled") }
    static var scrobblePlayedThrough: String { tr("เล่นครบ", "Played through") }
    static var scrobbleMinLength: String { tr("เพลงต้องยาวอย่างน้อย", "Minimum track length") }
    static var scrobbleSeconds: String { tr("วินาที", "seconds") }
    static var scrobbleFooter: String { tr("ค่ามาตรฐานของ Last.fm: 50% หรือ 4 นาที (อย่างใดอย่างหนึ่งถึงก่อน) และเพลงต้องยาวอย่างน้อย 30 วินาที", "Last.fm standard: 50% or 4 minutes (whichever comes first) and track must be at least 30 seconds") }
    static var scrobbleSources: String { tr("Scrobble ไป Last.fm จากแหล่ง", "Scrobble to Last.fm from sources") }
    static var scrobbleAppleMusic: String { tr("Apple Music", "Apple Music") }
    static var scrobbleSpotify: String { tr("Spotify", "Spotify") }

    // MARK: - Notifications

    static var notifTitle: String { tr("การแจ้งเตือน", "Notifications") }
    static var notifSubtitle: String { tr("Banner ของ macOS เมื่อมีกิจกรรมการฟัง", "macOS banners on listening activity") }
    static var notifEnable: String { tr("เปิดการแจ้งเตือน", "Enable notifications") }
    static var notifOnPlay: String { tr("เมื่อเริ่มเล่นเพลง", "When a track starts playing") }
    static var notifOnScrobble: String { tr("เมื่อ Scrobble สำเร็จ", "When scrobble succeeds") }
    static var notifPermissionDenied: String { tr("macOS ปฏิเสธการแจ้งเตือน — ไปเปิดใน System Settings → Notifications → Musique", "macOS denied notifications — enable in System Settings → Notifications → Musique") }

    // MARK: - Webhooks

    static var webhookTitle: String { tr("Webhooks", "Webhooks") }
    static var webhookSubtitle: String { tr("POST JSON ไปยัง endpoint ของคุณเมื่อมี event", "POST JSON to your endpoint on events") }
    static var webhookEnable: String { tr("เปิดใช้งาน Webhooks", "Enable Webhooks") }
    static var webhookOff: String { tr("ปิด", "Off") }
    static func webhookEvery(_ s: Int) -> String { tr("ทุก \(s) วินาที", "Every \(s) seconds") }
    static var webhookFooter: String { tr("Payload format ตรงกับ Music-Scrobbler — eventName: nowplaying / paused / scrobble", "Payload format matches Music-Scrobbler — eventName: nowplaying / paused / scrobble") }
    static var webhookNoUrl: String { tr("ยังไม่มี URL", "No URLs yet") }
    static var webhookAdd: String { tr("เพิ่ม", "Add") }
    static var webhookDestination: String { tr("URL ปลายทาง", "Destination URLs") }

    // MARK: - Menu Bar

    static var menubarSubtitle: String { tr("ปรับว่า status item จะแสดงข้อมูลอะไรบ้าง", "Configure what the status item displays") }
    static var menubarShowIcon: String { tr("แสดงไอคอน ♪", "Show icon ♪") }
    static var menubarShowState: String { tr("แสดงสถานะการเล่น (▶ / ❙❙)", "Show playback state (▶ / ❙❙)") }
    static var menubarShowTrack: String { tr("แสดงชื่อเพลง", "Show track name") }
    static var menubarShowArtist: String { tr("แสดงศิลปิน", "Show artist") }
    static var menubarMaxLength: String { tr("ความยาวสูงสุด", "Max length") }
    static var menubarChars: String { tr("ตัวอักษร", "characters") }
    static var menubarFooter: String { tr("ตัวอย่าง: ♪ ▶ ชื่อเพลง — ศิลปิน", "Example: ♪ ▶ Track — Artist") }
    static var menubarFooterIsland: String { tr("แสดง artwork + ไอคอนเล่น + คลื่นเสียง", "Shows artwork + play icon + audio wave") }
    static var menubarStyle: String { tr("รูปแบบ", "Style") }
    static var menubarStyleText: String { tr("ข้อความ", "Text") }
    static var menubarStyleDynamicIsland: String { tr("Dynamic Island", "Dynamic Island") }

    // MARK: - Mini Player

    static var miniplayerSubtitle: String { tr("ปรับหน้าตา mini player ใน menu bar", "Customize the mini player in the menu bar") }
    static var miniplayerArtworkStyle: String { tr("รูปแบบ Artwork", "Artwork Style") }
    static var miniplayerClassic: String { tr("Classic — artwork ตรงกลาง", "Classic — centered artwork") }
    static var miniplayerImmersive: String { tr("Immersive — full-bleed", "Immersive — full-bleed") }
    static var miniplayerMetaDisplay: String { tr("ข้อมูลที่แสดง", "Display info") }
    static var miniplayerArtist: String { tr("ศิลปิน", "Artist") }
    static var miniplayerAlbum: String { tr("อัลบั้ม", "Album") }
    static var miniplayerArtistAlbum: String { tr("ศิลปิน — อัลบั้ม", "Artist — Album") }
    static var miniplayerAnimOff: String { tr("ปิด", "Off") }
    static var miniplayerAnimArt: String { tr("เฉพาะปก", "Artwork only") }
    static var miniplayerAnimFull: String { tr("เต็ม (รวม backdrop)", "Full (with backdrop)") }
    static var miniplayerAnimFullscreen: String { tr("แสดง Animation เต็มจอ", "Show fullscreen animation") }
    static var miniplayerNoTrack: String { tr("ยังไม่ได้เล่นเพลง", "No track playing") }
    static var miniplayerTrackTooShort: String { tr("เพลงสั้นเกินไป", "Track too short") }
    static var miniplayerOpenMusic: String { tr("เปิด Apple Music แล้วกด Play", "Open Apple Music and press Play") }
    static var miniplayerEditTitle: String { tr("แก้ข้อมูลเพลง", "Edit Track Info") }
    static func miniplayerEditFooter(_ artist: String, _ title: String) -> String {
        tr("จะใช้ค่าใหม่นี้ทุกครั้งที่ \"\(artist) — \(title)\" เล่นซ้ำ",
           "These values will apply every time \"\(artist) — \(title)\" plays")
    }
    static var miniplayerCancel: String { tr("ยกเลิก", "Cancel") }
    static var miniplayerSave: String { tr("บันทึก", "Save") }

    // MARK: - Lock Screen

    static var lockscreenSubtitle: String { tr("แสดงเพลงที่กำลังเล่นบนหน้าล็อก", "Show now-playing on the lock screen") }
    static var lockscreenEnable: String { tr("เปิดใช้งาน Lock Screen Player", "Enable Lock Screen Player") }
    static var lockscreenDescription: String { tr("แสดง now-playing เต็มจอเมื่อล็อกหน้าจอ macOS — ใช้เทคนิค shielding window จึงต้องการสิทธิ์เข้าถึงจอภาพระบบ", "Shows full-screen now-playing when macOS is locked — uses a shielding window technique that requires screen access permission") }
    static var lockscreenDisplay: String { tr("การแสดงผล", "Display") }
    static var lockscreenShowAlbum: String { tr("แสดงชื่ออัลบั้ม", "Show album name") }
    static var lockscreenShowProgress: String { tr("แสดงแถบความคืบหน้า", "Show progress bar") }
    static var lockscreenAnimArtwork: String { tr("ใช้ animated artwork (ถ้ามี)", "Use animated artwork (if available)") }
    static var lockscreenLiqoriaStyle: String { tr("Liqoria style (animated bg เต็มจอ + capsule)", "Liqoria style (full-screen animated bg + capsule)") }
    static var lockscreenSystemWallpaper: String { tr("ตั้ง artwork เป็น lock screen wallpaper จริง (กู้คืนตอนปลดล็อก)", "Set artwork as real lock screen wallpaper (restored on unlock)") }
    static var lockscreenMotionWallpaper: String { tr("Motion artwork เป็น video wallpaper จริงตอน lock screen (กู้คืนตอนปลดล็อก)", "Motion artwork as real video wallpaper on lock screen (restored on unlock)") }
    static var lockscreenPositioning: String { tr("การจัดชั้น (System-Level)", "Layering (System-Level)") }
    static var lockscreenSkyLevel: String { tr("ระดับชั้น (layer)", "Layer level") }
    static var lockscreenSkyLevelHint: String { tr("ชั้นที่วาด bg/overlay ตอน lock — สูงกว่า = อยู่บนสุด เหนือ widget/นาฬิกาของระบบ", "Layer the bg/overlay draws at when locked — higher sits on top, above system widgets/clock") }
    static var lockscreenSkyLevelTest: String { tr("โชว์ปุ่มทดสอบ layer บนหน้า lock", "Show layer test control on lock screen") }
    static var lockscreenSkyLevelTestHint: String { tr("ล็อกจอแล้วกด ◀ ▶ สลับ layer เห็นผลสดๆ ปิดเมื่อเทสเสร็จ", "Lock the screen, then tap ◀ ▶ to switch layers live. Turn off when done.") }
    static var lockscreenAppearance: String { tr("รูปลักษณ์", "Appearance") }
    static var lockscreenBgBlur: String { tr("ความเบลอพื้นหลัง", "Background blur") }
    static var lockscreenScreenPicker: String { tr("จอที่แสดง", "Display on") }
    static var lockscreenMainOnly: String { tr("จอหลักเท่านั้น", "Main display only") }
    static var lockscreenAllScreens: String { tr("ทุกจอ", "All displays") }
    static var lockscreenClockStyle: String { tr("สไตล์นาฬิกา (Glass)", "Clock style (Glass)") }
    static var lockscreenClockDynamicColor: String { tr("ใช้สีตามปกหน้าปก", "Use dynamic color from artwork") }
    static var lockscreenClockSolidColorStrength: String { tr("ความเข้มสี Solid", "Solid color strength") }

    // MARK: - Edit Rules

    static var editRulesSubtitle: String { tr("แก้ metadata อัตโนมัติก่อน scrobble / webhook", "Auto-edit metadata before scrobble / webhook") }
    static var editRulesNoRule: String { tr("ยังไม่มี rule", "No rules yet") }
    static var editRulesMatchHeader: String { tr("ค่าที่ต้องการตรงกัน (match)", "Match criteria") }
    static var editRulesArtistRequired: String { tr("Artist (ต้องระบุ)", "Artist (required)") }
    static var editRulesTrackOptional: String { tr("Track (ถ้ามี)", "Track (optional)") }
    static var editRulesAlbumOptional: String { tr("Album (ถ้ามี)", "Album (optional)") }
    static var editRulesReplaceHeader: String { tr("ค่าที่ต้องการแทน (เว้นว่าง = ใช้ของเดิม)", "Replacement (leave blank = keep original)") }
    static var editRulesNewArtist: String { tr("Artist ใหม่", "New Artist") }
    static var editRulesNewTrack: String { tr("Track ใหม่", "New Track") }
    static var editRulesNewAlbum: String { tr("Album ใหม่", "New Album") }
    static var editRulesAdd: String { tr("เพิ่ม Rule", "Add Rule") }

    // MARK: - History

    static var historyTitle: String { tr("ประวัติการเล่น", "Play History") }
    static func historyStats(total: Int, pending: Int) -> String {
        tr("\(total) events ทั้งหมด · \(pending) scrobble ค้าง",
           "\(total) total events · \(pending) pending scrobbles")
    }
    static var historyTime: String { tr("เวลา", "Time") }
    static var historyTrack: String { tr("เพลง", "Track") }

    // MARK: - General / Language

    static var languageTitle: String { tr("ภาษา", "Language") }
    static var languageThai: String { "ไทย" }
    static var languageEnglish: String { "English" }
}
