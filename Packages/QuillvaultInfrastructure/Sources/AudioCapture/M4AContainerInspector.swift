import Foundation

struct M4AContainerInspector {
  func isStructurallyInvalid(_ url: URL) -> Bool? {
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer {
        try? handle.close()
      }
      let fileSize = try handle.seekToEnd()
      guard fileSize >= 8 else {
        return true
      }

      var offset: UInt64 = 0
      var foundFileType = false
      var foundMovieMetadata = false
      while offset < fileSize {
        guard
          fileSize - offset >= 8,
          let header = try read(count: 8, at: offset, from: handle)
        else {
          return true
        }

        let size32 = unsignedInteger(header.prefix(4))
        let type = Array(header.dropFirst(4).prefix(4))
        var headerSize: UInt64 = 8
        let boxSize: UInt64
        switch size32 {
        case 0:
          boxSize = fileSize - offset
        case 1:
          guard
            let extendedSize = try read(
              count: 8,
              at: offset + 8,
              from: handle
            )
          else {
            return true
          }
          headerSize = 16
          boxSize = unsignedInteger(extendedSize)
        default:
          boxSize = size32
        }

        guard
          boxSize >= headerSize,
          boxSize <= fileSize - offset
        else {
          return true
        }
        foundFileType = foundFileType || type == [0x66, 0x74, 0x79, 0x70]
        foundMovieMetadata =
          foundMovieMetadata || type == [0x6D, 0x6F, 0x6F, 0x76]
        offset += boxSize
      }
      return !foundFileType || !foundMovieMetadata
    } catch {
      return nil
    }
  }

  private func read(
    count: Int,
    at offset: UInt64,
    from handle: FileHandle
  ) throws -> Data? {
    try handle.seek(toOffset: offset)
    guard
      let data = try handle.read(upToCount: count),
      data.count == count
    else {
      return nil
    }
    return data
  }

  private func unsignedInteger<S: Sequence>(
    _ bytes: S
  ) -> UInt64 where S.Element == UInt8 {
    bytes.reduce(0) { value, byte in
      (value << 8) | UInt64(byte)
    }
  }
}
