// SPDX-License-Identifier: MIT
import AIModelOptions
import AIConnect

/// Voice-layer name for the Linux-tested streaming chunker. The first spoken
/// piece waits for a complete sentence so intonation stays intact.
public typealias StreamingSpeechSegmenter = StreamingSpeechChunker
