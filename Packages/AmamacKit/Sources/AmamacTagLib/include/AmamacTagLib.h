#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Where a file keeps the fields this helper reads and writes.
typedef NS_ENUM(NSInteger, AMTTagFormat) {
    /// Neither: these fields go through SFBAudioEngine (Xiph comments, APE tags).
    AMTTagFormatOther NS_SWIFT_NAME(other) = 0,
    /// ID3v2 frames TDRC, TDOR and TSRC (MP3, WAV, AIFF, TTA, DSF, DSDIFF).
    AMTTagFormatID3v2 NS_SWIFT_NAME(id3v2),
    /// MP4 `©day` and the freeform items `----:com.apple.iTunes:ORIGINALDATE` and `…:ISRC`.
    AMTTagFormatMP4 NS_SWIFT_NAME(mp4),
} NS_SWIFT_NAME(TagLibFormat);

/// Field values exactly as a file stores them; nil when absent.
NS_SWIFT_NAME(TagLibFieldValues)
NS_SWIFT_SENDABLE
@interface AMTFieldValues : NSObject
@property (nonatomic, readonly, copy, nullable) NSString *releaseDate;
@property (nonatomic, readonly, copy, nullable) NSString *originalDate;
@property (nonatomic, readonly, copy, nullable) NSString *isrc;
- (instancetype)initWithReleaseDate:(nullable NSString *)releaseDate
                       originalDate:(nullable NSString *)originalDate
                               isrc:(nullable NSString *)isrc NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Reads and writes the release date, original date and ISRC with TagLib, opening and saving
/// files the way SFBAudioEngine 0.14 does. SFBAudioEngine drops an ID3v2 TDRC frame unless the
/// date is a full timestamp, and has no field for original dates or MP4 ISRCs, so Amamac writes
/// these itself.
NS_SWIFT_NAME(TagLibFields)
@interface AMTFields : NSObject

/// The format family of the file at `url`, from its extension (as SFBAudioEngine chooses).
+ (AMTTagFormat)formatOfURL:(NSURL *)url NS_SWIFT_NAME(format(of:));

/// The values stored in the file. Returns nil and sets `error` when the file can't be read.
+ (nullable AMTFieldValues *)readFromURL:(NSURL *)url error:(NSError **)error NS_SWIFT_NAME(read(from:));

/// Writes the values: nil leaves a field untouched, an empty string removes it, anything else is
/// stored exactly. Other tags and frames are kept. The file is saved only when something changed.
+ (BOOL)writeReleaseDate:(nullable NSString *)releaseDate
            originalDate:(nullable NSString *)originalDate
                    isrc:(nullable NSString *)isrc
                   toURL:(NSURL *)url
                   error:(NSError **)error NS_SWIFT_NAME(write(releaseDate:originalDate:isrc:to:));

- (instancetype)init NS_UNAVAILABLE;

@end

/// Error domain for `AMTFields`; codes are `AMTFieldsErrorCode`.
FOUNDATION_EXPORT NSErrorDomain const AMTFieldsErrorDomain;

typedef NS_ERROR_ENUM(AMTFieldsErrorDomain, AMTFieldsErrorCode) {
    AMTFieldsErrorUnsupportedFormat = 1,
    AMTFieldsErrorOpen,
    AMTFieldsErrorInvalidFile,
    AMTFieldsErrorSave,
    AMTFieldsErrorInternal,
};

NS_ASSUME_NONNULL_END
