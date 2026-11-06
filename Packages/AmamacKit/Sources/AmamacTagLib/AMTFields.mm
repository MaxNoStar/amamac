#import "AmamacTagLib.h"

#import <taglib/aifffile.h>
#import <taglib/dsdifffile.h>
#import <taglib/dsffile.h>
#import <taglib/id3v2tag.h>
#import <taglib/mp4file.h>
#import <taglib/mp4tag.h>
#import <taglib/mpegfile.h>
#import <taglib/textidentificationframe.h>
#import <taglib/tfilestream.h>
#import <taglib/trueaudiofile.h>
#import <taglib/wavfile.h>

#import <exception>

NSErrorDomain const AMTFieldsErrorDomain = @"AmamacTagLib.AMTFields";

namespace {

/// The TagLib file classes SFBAudioEngine 0.14 uses, by path extension.
enum class Kind { none, mpeg, wav, aiff, trueAudio, dsf, dsdiff, mp4 };

Kind kindOfURL(NSURL *url) {
    NSString *ext = url.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"mp3"]) return Kind::mpeg;
    if ([ext isEqualToString:@"wav"] || [ext isEqualToString:@"wave"]) return Kind::wav;
    if ([ext isEqualToString:@"aif"] || [ext isEqualToString:@"aiff"]) return Kind::aiff;
    if ([ext isEqualToString:@"tta"]) return Kind::trueAudio;
    if ([ext isEqualToString:@"dsf"]) return Kind::dsf;
    if ([ext isEqualToString:@"dff"]) return Kind::dsdiff;
    if ([ext isEqualToString:@"m4a"] || [ext isEqualToString:@"m4r"] || [ext isEqualToString:@"mp4"]) return Kind::mp4;
    return Kind::none;
}

/// The three fields, as ID3v2 frame ids and MP4 item keys.
struct Keys {
    const char *release;
    const char *original;
    const char *isrc;
};
const Keys kID3v2Keys = {"TDRC", "TDOR", "TSRC"};
const Keys kMP4Keys = {"\251day", "----:com.apple.iTunes:ORIGINALDATE", "----:com.apple.iTunes:ISRC"};

/// Values to write; nil leaves a field alone.
struct Values {
    NSString *_Nullable release;
    NSString *_Nullable original;
    NSString *_Nullable isrc;

    /// Whether writing adds something, so a missing tag must be created first.
    bool addsField() const { return release.length > 0 || original.length > 0 || isrc.length > 0; }
};

NSError *makeError(AMTFieldsErrorCode code, NSURL *url) {
    return [NSError errorWithDomain:AMTFieldsErrorDomain code:code userInfo:@{NSURLErrorKey: url}];
}

NSString *_Nullable toNSString(const TagLib::String &s) {
    return [NSString stringWithUTF8String:s.toCString(true)];
}

TagLib::String fromNSString(NSString *s) {
    return TagLib::String(s.UTF8String ?: "", TagLib::String::UTF8);
}

// MARK: ID3v2

NSString *_Nullable readFrame(const TagLib::ID3v2::Tag *tag, const char *frameID) {
    if (tag == nullptr) return nil;
    const auto &frames = tag->frameListMap()[frameID];
    return frames.isEmpty() ? nil : toNSString(frames.front()->toString());
}

/// Replaces every `frameID` frame with one holding `value` ("" removes them). Returns whether the tag changed.
bool writeFrame(TagLib::ID3v2::Tag *tag, const char *frameID, NSString *_Nullable value) {
    if (value == nil || tag == nullptr) return false;
    const auto &frames = tag->frameListMap()[frameID];
    if (value.length == 0) {
        if (frames.isEmpty()) return false;
        tag->removeFrames(frameID);
        return true;
    }
    const TagLib::String text = fromNSString(value);
    if (frames.size() == 1 && frames.front()->toString() == text) return false;
    tag->removeFrames(frameID);
    auto *frame = new TagLib::ID3v2::TextIdentificationFrame(frameID, text.isLatin1() ? TagLib::String::Latin1 : TagLib::String::UTF8);
    frame->setText(text);
    tag->addFrame(frame);
    return true;
}

// MARK: MP4

NSString *_Nullable readItem(const TagLib::MP4::Tag *tag, const char *key) {
    if (tag == nullptr || !tag->contains(key)) return nil;
    return toNSString(tag->item(key).toStringList().toString());
}

bool writeItem(TagLib::MP4::Tag *tag, const char *key, NSString *_Nullable value) {
    if (value == nil || tag == nullptr) return false;
    if (value.length == 0) {
        if (!tag->contains(key)) return false;
        tag->removeItem(key);
        return true;
    }
    const TagLib::StringList text(fromNSString(value));
    if (tag->contains(key) && tag->item(key).toStringList() == text) return false;
    tag->setItem(key, text);
    return true;
}

// MARK: Files

/// Opens the file the way SFBAudioEngine does (no audio properties) and hands it to `body`, which
/// returns whether it changed anything; the file is saved only then.
template <typename File, typename Body>
BOOL withFile(NSURL *url, bool readOnly, Body body, NSError **error) {
    TagLib::FileStream stream(url.fileSystemRepresentation, readOnly);
    if (!stream.isOpen()) {
        if (error) *error = makeError(AMTFieldsErrorOpen, url);
        return NO;
    }
    File file(&stream, false);
    if (!file.isValid()) {
        if (error) *error = makeError(AMTFieldsErrorInvalidFile, url);
        return NO;
    }
    if (body(file) && !readOnly && !file.save()) {
        if (error) *error = makeError(AMTFieldsErrorSave, url);
        return NO;
    }
    return YES;
}

/// Runs `body` on the file's ID3v2 tag (nil when absent, unless `create` is set).
template <typename Body>
BOOL withID3v2Tag(NSURL *url, Kind kind, bool readOnly, bool create, Body body, NSError **error) {
    switch (kind) {
        case Kind::mpeg:
            return withFile<TagLib::MPEG::File>(url, readOnly, [&](TagLib::MPEG::File &f) { return body(f.ID3v2Tag(create)); }, error);
        case Kind::wav:
            return withFile<TagLib::RIFF::WAV::File>(url, readOnly, [&](TagLib::RIFF::WAV::File &f) { return body(f.ID3v2Tag()); }, error);
        case Kind::aiff:
            return withFile<TagLib::RIFF::AIFF::File>(url, readOnly, [&](TagLib::RIFF::AIFF::File &f) { return body(f.tag()); }, error);
        case Kind::trueAudio:
            return withFile<TagLib::TrueAudio::File>(url, readOnly, [&](TagLib::TrueAudio::File &f) { return body(f.ID3v2Tag(create)); }, error);
        case Kind::dsf:
            return withFile<TagLib::DSF::File>(url, readOnly, [&](TagLib::DSF::File &f) { return body(f.tag()); }, error);
        case Kind::dsdiff:
            return withFile<TagLib::DSDIFF::File>(url, readOnly, [&](TagLib::DSDIFF::File &f) { return body(f.ID3v2Tag(create)); }, error);
        case Kind::mp4:
        case Kind::none:
            if (error) *error = makeError(AMTFieldsErrorUnsupportedFormat, url);
            return NO;
    }
}

} // namespace

@implementation AMTFieldValues

- (instancetype)initWithReleaseDate:(NSString *)releaseDate originalDate:(NSString *)originalDate isrc:(NSString *)isrc {
    if ((self = [super init])) {
        _releaseDate = [releaseDate copy];
        _originalDate = [originalDate copy];
        _isrc = [isrc copy];
    }
    return self;
}

@end

@implementation AMTFields

+ (AMTTagFormat)formatOfURL:(NSURL *)url {
    switch (kindOfURL(url)) {
        case Kind::none: return AMTTagFormatOther;
        case Kind::mp4: return AMTTagFormatMP4;
        default: return AMTTagFormatID3v2;
    }
}

+ (AMTFieldValues *)readFromURL:(NSURL *)url error:(NSError **)error {
    const Kind kind = kindOfURL(url);
    NSString *release = nil, *original = nil, *isrc = nil;
    try {
        BOOL ok;
        if (kind == Kind::mp4) {
            ok = withFile<TagLib::MP4::File>(url, true, [&](TagLib::MP4::File &f) {
                release = readItem(f.tag(), kMP4Keys.release);
                original = readItem(f.tag(), kMP4Keys.original);
                isrc = readItem(f.tag(), kMP4Keys.isrc);
                return false;
            }, error);
        } else {
            ok = withID3v2Tag(url, kind, true, false, [&](const TagLib::ID3v2::Tag *tag) {
                release = readFrame(tag, kID3v2Keys.release);
                original = readFrame(tag, kID3v2Keys.original);
                isrc = readFrame(tag, kID3v2Keys.isrc);
                return false;
            }, error);
        }
        return ok ? [[AMTFieldValues alloc] initWithReleaseDate:release originalDate:original isrc:isrc] : nil;
    } catch (const std::exception &) {
        if (error) *error = makeError(AMTFieldsErrorInternal, url);
        return nil;
    }
}

+ (BOOL)writeReleaseDate:(NSString *)releaseDate
            originalDate:(NSString *)originalDate
                    isrc:(NSString *)isrc
                   toURL:(NSURL *)url
                   error:(NSError **)error {
    const Values values = {releaseDate, originalDate, isrc};
    if (values.release == nil && values.original == nil && values.isrc == nil) return YES;
    const Kind kind = kindOfURL(url);
    try {
        if (kind == Kind::mp4) {
            return withFile<TagLib::MP4::File>(url, false, [&](TagLib::MP4::File &f) {
                const bool release = writeItem(f.tag(), kMP4Keys.release, values.release);
                const bool original = writeItem(f.tag(), kMP4Keys.original, values.original);
                const bool code = writeItem(f.tag(), kMP4Keys.isrc, values.isrc);
                return release || original || code;
            }, error);
        }
        return withID3v2Tag(url, kind, false, values.addsField(), [&](TagLib::ID3v2::Tag *tag) {
            const bool release = writeFrame(tag, kID3v2Keys.release, values.release);
            const bool original = writeFrame(tag, kID3v2Keys.original, values.original);
            const bool code = writeFrame(tag, kID3v2Keys.isrc, values.isrc);
            return release || original || code;
        }, error);
    } catch (const std::exception &) {
        if (error) *error = makeError(AMTFieldsErrorInternal, url);
        return NO;
    }
}

@end
