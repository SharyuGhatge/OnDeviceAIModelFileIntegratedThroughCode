#import <React/RCTBridgeModule.h>
#import <React/RCTUtils.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <UIKit/UIKit.h>
#import <PDFKit/PDFKit.h>
#import <zlib.h>

static uint16_t ReadLE16(const uint8_t *bytes, NSUInteger offset)
{
  return (uint16_t)bytes[offset] | ((uint16_t)bytes[offset + 1] << 8);
}

static uint32_t ReadLE32(const uint8_t *bytes, NSUInteger offset)
{
  return (uint32_t)bytes[offset] | ((uint32_t)bytes[offset + 1] << 8) |
      ((uint32_t)bytes[offset + 2] << 16) | ((uint32_t)bytes[offset + 3] << 24);
}

@interface DocumentFilePicker : NSObject <RCTBridgeModule, UIDocumentPickerDelegate, NSXMLParserDelegate>
@property (nonatomic, copy) RCTPromiseResolveBlock resolve;
@property (nonatomic, copy) RCTPromiseRejectBlock reject;
@property (nonatomic, strong) NSMutableString *docxText;
@property (nonatomic, assign) BOOL readingDocxText;
@end

@implementation DocumentFilePicker

RCT_EXPORT_MODULE();

RCT_REMAP_METHOD(pickDocument,
                 pickDocumentWithResolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject)
{
  if (self.resolve != nil) {
    reject(@"E_PICKER_BUSY", @"A file picker is already open.", nil);
    return;
  }

  self.resolve = resolve;
  self.reject = reject;
  dispatch_async(dispatch_get_main_queue(), ^{
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypePlainText, UTTypeMarkdown, UTTypePDF, [UTType typeWithIdentifier:@"org.openxmlformats.wordprocessingml.document"]] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    UIViewController *presenter = RCTPresentedViewController();
    if (presenter == nil) {
      [self finishWithError:@"E_NO_VIEW_CONTROLLER" message:@"The file picker could not be presented."];
      return;
    }
    [presenter presentViewController:picker animated:YES completion:nil];
  });
}

RCT_REMAP_METHOD(extractPdfText,
                 extractPdfTextAtPath:(NSString *)path
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject)
{
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    PDFDocument *document = [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:path]];
    NSString *text = document.string;
    if (document == nil || text == nil) {
      reject(@"E_PDF_EXTRACTION", @"The PDF could not be read. It may be password-protected or damaged.", nil);
      return;
    }
    resolve(text);
  });
}

RCT_REMAP_METHOD(extractDocxText,
                 extractDocxTextAtPath:(NSString *)path
                 docxResolver:(RCTPromiseResolveBlock)resolve
                 docxRejecter:(RCTPromiseRejectBlock)reject)
{
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSData *archive = [NSData dataWithContentsOfFile:path];
    const uint8_t *bytes = archive.bytes;
    NSUInteger length = archive.length;
    NSUInteger searchStart = length > 65557 ? length - 65557 : 0;
    NSInteger eocd = -1;
    if (length >= 22) {
      for (NSInteger offset = (NSInteger)length - 22; offset >= (NSInteger)searchStart; offset--) {
        if (ReadLE32(bytes, (NSUInteger)offset) == 0x06054b50) { eocd = offset; break; }
      }
    }
    NSData *xml = nil;
    if (eocd >= 0) {
      NSUInteger directoryOffset = ReadLE32(bytes, (NSUInteger)eocd + 16);
      NSUInteger directoryEnd = MIN(length, directoryOffset + ReadLE32(bytes, (NSUInteger)eocd + 12));
      for (NSUInteger cursor = directoryOffset; cursor + 46 <= directoryEnd && ReadLE32(bytes, cursor) == 0x02014b50;) {
        uint16_t nameLength = ReadLE16(bytes, cursor + 28);
        uint16_t extraLength = ReadLE16(bytes, cursor + 30);
        uint16_t commentLength = ReadLE16(bytes, cursor + 32);
        NSUInteger next = cursor + 46 + nameLength + extraLength + commentLength;
        if (next > directoryEnd) break;
        NSString *name = [[NSString alloc] initWithBytes:bytes + cursor + 46 length:nameLength encoding:NSUTF8StringEncoding];
        if ([name isEqualToString:@"word/document.xml"]) {
          uint16_t method = ReadLE16(bytes, cursor + 10);
          NSUInteger compressedLength = ReadLE32(bytes, cursor + 20);
          NSUInteger uncompressedLength = ReadLE32(bytes, cursor + 24);
          NSUInteger localOffset = ReadLE32(bytes, cursor + 42);
          if (localOffset + 30 <= length && ReadLE32(bytes, localOffset) == 0x04034b50) {
            NSUInteger dataOffset = localOffset + 30 + ReadLE16(bytes, localOffset + 26) + ReadLE16(bytes, localOffset + 28);
            if (dataOffset + compressedLength <= length) {
              NSData *compressed = [archive subdataWithRange:NSMakeRange(dataOffset, compressedLength)];
              if (method == 0) xml = compressed;
              else if (method == 8 && uncompressedLength > 0) {
                NSMutableData *inflated = [NSMutableData dataWithLength:uncompressedLength];
                z_stream stream = {0};
                stream.next_in = (Bytef *)compressed.bytes;
                stream.avail_in = (uInt)compressed.length;
                stream.next_out = (Bytef *)inflated.mutableBytes;
                stream.avail_out = (uInt)inflated.length;
                if (inflateInit2(&stream, -MAX_WBITS) == Z_OK) {
                  if (inflate(&stream, Z_FINISH) == Z_STREAM_END) xml = inflated;
                  inflateEnd(&stream);
                }
              }
            }
          }
          break;
        }
        cursor = next;
      }
    }
    if (xml == nil) {
      reject(@"E_DOCX_EXTRACTION", @"The Word document could not be read.", nil);
      return;
    }
    DocumentFilePicker *picker = [DocumentFilePicker new];
    picker.docxText = [NSMutableString string];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:xml];
    parser.delegate = picker;
    if (![parser parse]) {
      reject(@"E_DOCX_EXTRACTION", @"The Word document could not be read.", parser.parserError);
      return;
    }
    resolve(picker.docxText);
  });
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qualifiedName attributes:(NSDictionary<NSString *, NSString *> *)attributeDict
{
  NSString *localName = elementName.pathExtension.length ? elementName.pathExtension : [[elementName componentsSeparatedByString:@":"] lastObject];
  if ([localName isEqualToString:@"t"]) self.readingDocxText = YES;
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string
{
  if (self.readingDocxText) [self.docxText appendString:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName
{
  NSString *localName = elementName.pathExtension.length ? elementName.pathExtension : [[elementName componentsSeparatedByString:@":"] lastObject];
  if ([localName isEqualToString:@"t"]) self.readingDocxText = NO;
  if ([localName isEqualToString:@"p"]) [self.docxText appendString:@"\n"];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
  NSURL *sourceURL = urls.firstObject;
  if (sourceURL == nil) {
    [self finishWithError:@"E_INVALID_FILE" message:@"No file was selected."];
    return;
  }
  NSString *fileExtension = sourceURL.pathExtension.lowercaseString;
  if (![fileExtension isEqualToString:@"txt"] && ![fileExtension isEqualToString:@"md"] && ![fileExtension isEqualToString:@"pdf"] && ![fileExtension isEqualToString:@"docx"]) {
    [self finishWithError:@"E_UNSUPPORTED_FILE" message:@"Choose a .txt, .md, .pdf, or Word (.docx) file."];
    return;
  }

  BOOL accessed = [sourceURL startAccessingSecurityScopedResource];
  NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
  NSString *storedFileName = [NSString stringWithFormat:@"%@-%@", [[NSUUID UUID] UUIDString], sourceURL.lastPathComponent];
  NSURL *destinationURL = [documentsURL URLByAppendingPathComponent:storedFileName];
  __block BOOL copied = NO;
  __block NSError *coordinationError = nil;
  if (accessed || sourceURL.isFileURL) {
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateReadingItemAtURL:sourceURL options:0 error:&coordinationError byAccessor:^(NSURL * _Nonnull coordinatedURL) {
      NSFileManager *fileManager = [NSFileManager defaultManager];
      NSError *itemCopyError = nil;
      copied = [fileManager copyItemAtURL:coordinatedURL toURL:destinationURL error:&itemCopyError];
      if (itemCopyError != nil) coordinationError = itemCopyError;
    }];
  } else {
    copied = NO;
  }
  if (accessed) [sourceURL stopAccessingSecurityScopedResource];

  if (!copied) {
    [self finishWithError:@"E_DOCUMENT_COPY" message:coordinationError.localizedDescription ?: @"The selected file could not be copied into app storage."];
    return;
  }

  RCTPromiseResolveBlock resolve = self.resolve;
  self.resolve = nil;
  self.reject = nil;
  resolve(@{@"path": destinationURL.path, @"name": sourceURL.lastPathComponent});
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
  RCTPromiseResolveBlock resolve = self.resolve;
  self.resolve = nil;
  self.reject = nil;
  if (resolve != nil) resolve(nil);
}

- (void)finishWithError:(NSString *)code message:(NSString *)message
{
  RCTPromiseRejectBlock reject = self.reject;
  self.resolve = nil;
  self.reject = nil;
  if (reject != nil) reject(code, message, nil);
}

@end
