// =============================================================================
// VAST Parser - Implementation
// Parses VAST 4.0/4.1 XML for video ad serving
// =============================================================================

import Foundation

// MARK: - VAST Models

/// VAST response container
public struct VASTResponse {
    public let version: String
    public let ad: VASTAd?
    public let error: VASTError?

    public init(version: String, ad: VASTAd?, error: VASTError? = nil) {
        self.version = version
        self.ad = ad
        self.error = error
    }
}

/// VAST Ad element
public struct VASTAd {
    public let id: String
    public let adSystem: String
    public let title: String
    public let mediaFiles: [VASTMediaFile]
    public let trackingEvents: [VASTTrackingEvent]
    public let companionAds: [VASTCompanionAd]
    public let duration: TimeInterval
    public let clickThroughURL: String?

    public init(
        id: String,
        adSystem: String,
        title: String,
        mediaFiles: [VASTMediaFile],
        trackingEvents: [VASTTrackingEvent],
        companionAds: [VASTCompanionAd] = [],
        duration: TimeInterval,
        clickThroughURL: String? = nil
    ) {
        self.id = id
        self.adSystem = adSystem
        self.title = title
        self.mediaFiles = mediaFiles
        self.trackingEvents = trackingEvents
        self.companionAds = companionAds
        self.duration = duration
        self.clickThroughURL = clickThroughURL
    }
}

/// VAST MediaFile element
public struct VASTMediaFile {
    public let url: String
    public let delivery: String
    public let type: String
    public let width: Int
    public let height: Int
    public let bitrate: Int
    public let codec: String?

    public init(
        url: String,
        delivery: String = "progressive",
        type: String,
        width: Int,
        height: Int,
        bitrate: Int,
        codec: String? = nil
    ) {
        self.url = url
        self.delivery = delivery
        self.type = type
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.codec = codec
    }
}

/// VAST Tracking Event
public struct VASTTrackingEvent {
    public let event: VASTEventType
    public let url: String

    public init(event: VASTEventType, url: String) {
        self.event = event
        self.url = url
    }
}

/// VAST Event Types
public enum VASTEventType: String, Hashable {
    case start
    case firstQuartile
    case midpoint
    case thirdQuartile
    case complete
    case mute
    case unmute
    case pause
    case resume
    case skip
    case close
    case click
    case impression
}

/// VAST Companion Ad
public struct VASTCompanionAd {
    public let width: Int
    public let height: Int
    public let staticResource: String?
    public let clickThrough: String?

    public init(width: Int, height: Int, staticResource: String?, clickThrough: String?) {
        self.width = width
        self.height = height
        self.staticResource = staticResource
        self.clickThrough = clickThrough
    }
}

/// VAST Error
public enum VASTError: Error, Equatable {
    case invalidXML
    case noAd
    case noMediaFile
    case unsupportedVersion
    case networkError
    case unknown
}

// MARK: - VAST Parser

/// Parses VAST XML into structured data
public class VASTParser: NSObject {

    private var vastResponse: VASTResponse?
    private var parseError: Error?

    // Current parsing state
    private var currentElement: String = ""
    private var currentText: String = ""

    // Parsed values
    private var version: String = ""
    private var adID: String = ""
    private var adSystem: String = ""
    private var adTitle: String = ""
    private var duration: TimeInterval = 0
    private var clickThroughURL: String?

    private var mediaFiles: [VASTMediaFile] = []
    private var trackingEvents: [VASTTrackingEvent] = []
    private var companionAds: [VASTCompanionAd] = []

    // Current media file being parsed
    private var currentMediaFile: (delivery: String, type: String, width: Int, height: Int, bitrate: Int)?

    // Current tracking event
    private var currentTrackingEvent: String?

    public func parse(_ xmlString: String) -> Result<VASTResponse, PerspicisError> {
        guard let data = xmlString.data(using: .utf8) else {
            return .failure(.vastParseError)
        }

        let parser = XMLParser(data: data)
        parser.delegate = self

        if parser.parse(), let response = buildResponse() {
            return .success(response)
        } else {
            return .failure(.vastParseError)
        }
    }

    private func buildResponse() -> VASTResponse? {
        guard !version.isEmpty else { return nil }

        let ad: VASTAd?
        if !adID.isEmpty || !mediaFiles.isEmpty {
            ad = VASTAd(
                id: adID,
                adSystem: adSystem,
                title: adTitle,
                mediaFiles: mediaFiles,
                trackingEvents: trackingEvents,
                companionAds: companionAds,
                duration: duration,
                clickThroughURL: clickThroughURL
            )
        } else {
            ad = nil
        }

        return VASTResponse(version: version, ad: ad)
    }

    private func parseDuration(_ durationString: String) -> TimeInterval {
        // Format: HH:MM:SS or HH:MM:SS.mmm
        let components = durationString.split(separator: ":")
        guard components.count == 3 else { return 0 }

        let hours = Double(components[0]) ?? 0
        let minutes = Double(components[1]) ?? 0

        // Handle seconds with optional milliseconds
        let secondsString = String(components[2])
        let seconds = Double(secondsString.split(separator: ".").first ?? "") ?? 0

        return hours * 3600 + minutes * 60 + seconds
    }
}

// MARK: - XMLParserDelegate

extension VASTParser: XMLParserDelegate {

    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""

        switch elementName {
        case "VAST":
            version = attributeDict["version"] ?? ""

        case "Ad":
            adID = attributeDict["id"] ?? ""

        case "MediaFile":
            currentMediaFile = (
                delivery: attributeDict["delivery"] ?? "progressive",
                type: attributeDict["type"] ?? "",
                width: Int(attributeDict["width"] ?? "0") ?? 0,
                height: Int(attributeDict["height"] ?? "0") ?? 0,
                bitrate: Int(attributeDict["bitrate"] ?? "0") ?? 0
            )

        case "Tracking":
            currentTrackingEvent = attributeDict["event"]

        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "AdSystem":
            adSystem = currentText

        case "AdTitle":
            adTitle = currentText

        case "Duration":
            duration = parseDuration(currentText)

        case "ClickThrough":
            clickThroughURL = currentText

        case "MediaFile":
            if let mf = currentMediaFile, !currentText.isEmpty {
                let mediaFile = VASTMediaFile(
                    url: currentText,
                    delivery: mf.delivery,
                    type: mf.type,
                    width: mf.width,
                    height: mf.height,
                    bitrate: mf.bitrate
                )
                mediaFiles.append(mediaFile)
            }
            currentMediaFile = nil

        case "Tracking":
            if let eventName = currentTrackingEvent,
               let eventType = VASTEventType(rawValue: eventName),
               !currentText.isEmpty {
                let event = VASTTrackingEvent(event: eventType, url: currentText)
                trackingEvents.append(event)
            }
            currentTrackingEvent = nil

        default:
            break
        }

        currentElement = ""
        currentText = ""
    }

    public func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}
