import XCTest
@testable import CastKit

/// Video: what a LOAD carries (an episode's metadata, subtitle tracks, HLS hints), and turning
/// subtitles on and off and changing speed on a receiver.
final class CastVideoTests: XCTestCase {
  var receiver: FakeReceiver!
  var client: CastClient!
  var delegate: RecordingDelegate!
  var app: CastApp!

  override func setUpWithError() throws {
    receiver = try FakeReceiver()
    try receiver.start()
    delegate = RecordingDelegate()
    client = CastClient(device: receiver.device)
    client.usesTLS = false
    client.delegate = delegate
    client.connect()
    wait(for: [delegate.connected], timeout: 5)
    let launched = expectation(description: "launched")
    let box = ResultBox<CastApp>()
    client.launch(appId: CastAppIdentifier.defaultMediaPlayer) { result in
      box.value = result
      launched.fulfill()
    }
    wait(for: [launched], timeout: 5)
    app = try XCTUnwrap(box.value).get()
  }

  override func tearDown() {
    client.delegate = nil
    client.disconnect()
    receiver.stop()
  }

  private var episode: CastMedia {
    CastMedia(url: URL(string: "http://10.0.0.2:8080/s/master.m3u8")!, contentType: "application/x-mpegurl",
              metadata: .tvShow(seriesTitle: "Neagley", episodeTitle: "Team Building Exercises", season: 1, episode: 2),
              poster: URL(string: "http://10.0.0.2:8080/s/still.jpg"), duration: 2_820,
              tracks: [CastMediaTrack(id: 1, contentID: URL(string: "http://10.0.0.2:8080/s/en.vtt"), name: "English", language: "en"),
                       CastMediaTrack(id: 2, contentID: URL(string: "http://10.0.0.2:8080/s/es.vtt"), name: "Español", language: "es")],
              activeTrackIds: [1], textTrackStyle: CastTextTrackStyle(fontScale: 1.2),
              hlsSegmentFormat: "fmp4", hlsVideoSegmentFormat: "fmp4", currentTime: 600)
  }

  func testTheLoadCarriesTheEpisodeAndItsSubtitles() throws {
    let media = episode.mediaDict
    let metadata = try XCTUnwrap(media["metadata"] as? [String: Any])
    XCTAssertEqual(metadata["metadataType"] as? Int, 2)
    XCTAssertEqual(metadata["seriesTitle"] as? String, "Neagley")
    XCTAssertEqual(metadata["title"] as? String, "Team Building Exercises")
    XCTAssertEqual(metadata["season"] as? Int, 1)
    XCTAssertEqual(metadata["episode"] as? Int, 2)
    XCTAssertEqual(media["duration"] as? Double, 2_820)
    XCTAssertEqual(media["hlsSegmentFormat"] as? String, "fmp4")
    XCTAssertEqual(media["hlsVideoSegmentFormat"] as? String, "fmp4")
    let tracks = try XCTUnwrap(media["tracks"] as? [[String: Any]])
    XCTAssertEqual(tracks.map { $0["trackId"] as? Int }, [1, 2])
    XCTAssertEqual(tracks.first?["type"] as? String, "TEXT")
    XCTAssertEqual(tracks.first?["subtype"] as? String, "SUBTITLES")
    XCTAssertEqual(tracks.first?["trackContentType"] as? String, "text/vtt")
    XCTAssertEqual(tracks.last?["language"] as? String, "es")
    XCTAssertEqual((media["textTrackStyle"] as? [String: Any])?["fontScale"] as? Double, 1.2)
    XCTAssertEqual(episode.dict["activeTrackIds"] as? [Int], [1])
    XCTAssertEqual(episode.dict["currentTime"] as? Double, 600)
    XCTAssertEqual(episode.title, "Team Building Exercises")
  }

  func testAMovieAndTheOldMusicInitializer() {
    let movie = CastMedia(url: URL(string: "http://x/m.m3u8")!, contentType: "application/x-mpegurl",
                          metadata: .movie(title: "Low Orbit", subtitle: "2022 · PG-13"))
    XCTAssertEqual((movie.metadataDict["metadataType"] as? Int), 1)
    XCTAssertEqual((movie.metadataDict["subtitle"] as? String), "2022 · PG-13")
    XCTAssertNil(movie.mediaDict["tracks"], "no tracks, no key")
    // Highnote's songs: unchanged.
    let song = CastMedia(title: "Song", artist: "Band", url: URL(string: "http://x/a.mp3")!, contentType: "audio/mpeg")
    XCTAssertEqual(song.metadataDict["metadataType"] as? Int, 3)
    XCTAssertEqual(song.metadataDict["artist"] as? String, "Band")
    XCTAssertEqual(song.dict["activeTrackIds"] as? [Int], [])
  }

  func testSubtitlesAreSwitchedOnTheSession() throws {
    let loaded = expectation(description: "loaded")
    client.load(media: episode, with: app) { _ in loaded.fulfill() }
    wait(for: [loaded], timeout: 5)
    XCTAssertEqual((receiver.received.last(where: { $0.type == "LOAD" })?.json["media"] as? [String: Any])?["contentType"] as? String,
                   "application/x-mpegurl")

    let switched = expectation(description: "tracks edited")
    let box = ResultBox<CastMediaStatus>()
    client.editTracks(activeTrackIds: [2], textTrackStyle: CastTextTrackStyle(fontScale: 0.8)) { result in
      box.value = result
      switched.fulfill()
    }
    wait(for: [switched], timeout: 5)
    XCTAssertEqual(try XCTUnwrap(box.value).get().activeTrackIds, [2])
    let sent = try XCTUnwrap(receiver.received.last(where: { $0.namespace == CastNamespace.media && $0.type == "EDIT_TRACKS_INFO" }))
    XCTAssertNotNil(sent.json["mediaSessionId"])
    XCTAssertEqual((sent.json["textTrackStyle"] as? [String: Any])?["fontScale"] as? Double, 0.8)

    let off = expectation(description: "subtitles off")
    client.editTracks(activeTrackIds: []) { _ in off.fulfill() }
    wait(for: [off], timeout: 5)
    XCTAssertEqual(receiver.activeTrackIds, [])
  }

  func testPlaybackRate() throws {
    let loaded = expectation(description: "loaded")
    client.load(media: episode, with: app) { _ in loaded.fulfill() }
    wait(for: [loaded], timeout: 5)
    let set = expectation(description: "rate")
    let box = ResultBox<CastMediaStatus>()
    client.setPlaybackRate(1.5) { result in
      box.value = result
      set.fulfill()
    }
    wait(for: [set], timeout: 5)
    XCTAssertEqual(try XCTUnwrap(box.value).get().playbackRate, 1.5, accuracy: 0.001)
  }
}
