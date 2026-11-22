import CoreWLAN
import Foundation

/// Параметры Wi‑Fi интерфейса. SSID намеренно не читается (нужны права геолокации).
struct WiFiStatus: Sendable, Equatable {
    /// Уровень сигнала, дБм.
    let rssi: Int
    /// Уровень шума, дБм (nil, если система не сообщила).
    let noise: Int?
    /// Номер канала.
    let channel: Int?
    /// Диапазон: «2,4 ГГц» или «5 ГГц» (nil для остальных).
    let band: String?
    /// Скорость связи, Мбит/с (nil, если неизвестна).
    let txRate: Double?
}

enum WiFiProbe {
    /// nil — нет Wi‑Fi интерфейса, Wi‑Fi выключен или нет ассоциации с сетью.
    static func status() -> WiFiStatus? {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        let rssi = interface.rssiValue()
        // 0 означает, что интерфейс ни к чему не подключён.
        guard rssi < 0 else { return nil }

        let noiseValue = interface.noiseMeasurement()
        let channel = interface.wlanChannel()
        var band: String?
        if let channelBand = channel?.channelBand {
            if channelBand == .band2GHz {
                band = "2,4 ГГц"
            } else if channelBand == .band5GHz {
                band = "5 ГГц"
            }
        }
        let rate = interface.transmitRate()
        return WiFiStatus(rssi: rssi,
                          noise: noiseValue < 0 ? noiseValue : nil,
                          channel: channel?.channelNumber,
                          band: band,
                          txRate: rate > 0 ? rate : nil)
    }
}
