import Foundation

/// Why the lyrics area shows no lyrics, told apart the way Spicy Lyrics' `LyricsNotice.ts` does:
/// each cause has its own words, "Try again" only where a refetch can help, and "Copy details"
/// only where a report tells the developers something.
enum LyricsNotice: Equatable {
    case notFound
    case localTrack
    case episode
    case ad
    case unknownTrack
    case offline
    case serviceUnavailable
    case rateLimited
    case unauthorized
    /// No Spotify sign-in to ask Spicy Lyrics with, and no key of our own.
    case signedOut
    case serverError(Int)
    case unknownError

    /// The extension's descriptor, shown under the notice and in the copied details.
    var code: String {
        switch self {
        case .notFound: return "lyrics-not-found"
        case .localTrack: return "local-track"
        case .episode: return "episode-track"
        case .ad: return "ad"
        case .unknownTrack: return "unknown-track"
        case .offline: return "offline"
        case .serviceUnavailable: return "service-unavailable"
        case .rateLimited: return "rate-limited"
        case .unauthorized: return "unauthorized"
        case .signedOut: return "signed-out"
        case .serverError(let status): return "status-not-200 (\(status))"
        case .unknownError: return "unknown-error"
        }
    }

    var icon: String {
        switch self {
        case .notFound: return "text.badge.xmark"
        case .localTrack: return "doc.badge.ellipsis"
        case .episode: return "mic"
        case .ad: return "megaphone"
        case .unknownTrack: return "questionmark.circle"
        case .offline: return "wifi.slash"
        case .serviceUnavailable, .serverError: return "exclamationmark.icloud"
        case .rateLimited: return "hourglass"
        case .unauthorized, .signedOut: return "key.horizontal"
        case .unknownError: return "exclamationmark.triangle"
        }
    }

    var title: String {
        switch self {
        case .notFound: return String(localized: "Текста для этой песни пока нет")
        case .localTrack: return String(localized: "Для локальных файлов текста нет")
        case .episode: return String(localized: "У подкастов нет текста")
        case .ad: return String(localized: "Реклама")
        case .unknownTrack: return String(localized: "Не удалось распознать трек")
        case .offline: return String(localized: "Нет интернета")
        case .serviceUnavailable: return String(localized: "Тексты временно недоступны")
        case .rateLimited: return String(localized: "Слишком много запросов")
        case .unauthorized: return String(localized: "Сервер не принял авторизацию")
        case .signedOut: return String(localized: "Нужен вход в Spotify")
        case .serverError: return String(localized: "Сервер текстов вернул ошибку")
        case .unknownError: return String(localized: "Что-то пошло не так")
        }
    }

    var body: String? {
        switch self {
        case .notFound:
            return String(localized: "Ни в одном из источников нет текста для этого трека. Новые тексты добавляют постоянно, загляните позже. Если вы знаете, что текст у песни есть, скопируйте детали и отправьте нам.")
        case .localTrack:
            return String(localized: "Это файл с устройства, его не найти в каталогах. Свой текст можно добавить как TTML в меню трека.")
        case .episode:
            return String(localized: "Тексты показываются только для песен.")
        case .ad:
            return nil
        case .unknownTrack:
            return String(localized: "Плеер не сказал, что играет, поэтому непонятно, какой текст искать. Обычно помогает переключиться на следующую песню и обратно.")
        case .offline:
            return String(localized: "Текст песни скачивается при первом прослушивании. Недавние песни сохранены и без сети. Подключитесь и попробуйте снова.")
        case .serviceUnavailable:
            return String(localized: "Сервис текстов сейчас не отвечает. С вашей стороны всё в порядке, попробуйте через минуту.")
        case .rateLimited:
            return String(localized: "За короткое время запросили много песен, сервер просит подождать. Попробуйте через несколько секунд.")
        case .unauthorized:
            return String(localized: "Spicy Lyrics не принял вход. Попробуйте снова; если не поможет, добавьте свой ключ sl_pk_ в настройках.")
        case .signedOut:
            return String(localized: "Тексты Spicy Lyrics запрашиваются от вашего аккаунта Spotify. Войдите в настройках или добавьте свой ключ sl_pk_.")
        case .serverError:
            return String(localized: "На этой песне сервер ответил ошибкой. Попробуйте чуть позже. Если повторяется, скопируйте детали и отправьте нам.")
        case .unknownError:
            return String(localized: "Текст не загрузился из-за неожиданной ошибки. Попробуйте снова, а если повторяется, отправьте нам детали.")
        }
    }

    /// The cause is temporary and a refetch can clear it.
    var retry: Bool {
        switch self {
        case .offline, .serviceUnavailable, .rateLimited, .unauthorized, .signedOut, .serverError, .unknownError: return true
        case .notFound, .localTrack, .episode, .ad, .unknownTrack: return false
        }
    }

    /// A report tells us something; states that work as designed (podcasts, local files) don't.
    var report: Bool {
        switch self {
        case .notFound, .unknownTrack, .serviceUnavailable, .rateLimited, .unauthorized, .serverError, .unknownError: return true
        case .localTrack, .episode, .ad, .offline, .signedOut: return false
        }
    }

    /// Only says the song has no lyrics: "Hide «No lyrics found»" hides these too, errors keep theirs.
    var isNoLyrics: Bool {
        switch self {
        case .notFound, .localTrack, .episode, .ad: return true
        default: return false
        }
    }

    /// The notice for an error from a lyrics request.
    static func classify(_ error: Error) -> LyricsNotice {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
                 .callIsActive:
                return .offline
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed,
                 .badServerResponse:
                return .serviceUnavailable
            default:
                return .unknownError
            }
        }
        if let auth = error as? SpotifyAuthError {
            switch auth {
            case .notLoggedIn, .missingClientID, .cancelled: return .signedOut
            case .badCallback, .tokenEndpoint: return .unauthorized
            }
        }
        if let status = (error as? HTTPStatusError)?.status {
            switch status {
            case 429: return .rateLimited
            case 401, 403: return .unauthorized
            case 500...599: return .serviceUnavailable
            default: return .serverError(status)
            }
        }
        return .unknownError
    }
}

/// An error that carries the HTTP status it came from, for `LyricsNotice.classify`.
protocol HTTPStatusError: Error {
    var status: Int? { get }
}

/// A lookup that failed: why, which source said so and its own words, for the copied details.
struct LyricsFailure: Equatable {
    var notice: LyricsNotice
    /// "Spicy Lyrics: HTTP 502", one line per source that failed.
    var detail: String
    var source: String?
}
