import AudioToolbox
import Testing
@testable import Scribe

struct AudioRecorderTests {
    @Test
    func coreAudioInputDevicesHaveStableIdentifiers() {
        let devices = AudioInputDevice.available()

        #expect(!devices.isEmpty)
        #expect(devices.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty })
        #expect(devices.count(where: \.isDefault) <= 1)
    }

    @Test
    func fileFormatInterleavesMultichannelPCM() {
        let clientFormat = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let fileFormat = interleavedAudioFileFormat(clientFormat)

        #expect(fileFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)
        #expect(fileFormat.mBytesPerFrame == 8)
        #expect(fileFormat.mBytesPerPacket == 8)
    }
}
