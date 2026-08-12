#import "TwoShipTVOSFileServer.h"

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <Network/Network.h>

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <sys/socket.h>

#include <atomic>
#include <cstring>

namespace {

constexpr uint64_t kMaximumUploadBytes = 4ULL * 1024ULL * 1024ULL * 1024ULL;
constexpr size_t kMaximumHeaderBytes = 64 * 1024;

dispatch_queue_t ServerQueue() {
    static dispatch_queue_t queue =
        dispatch_queue_create("com.linkzenic.twoship.tvos-file-transfer", DISPATCH_QUEUE_SERIAL);
    return queue;
}

NSObject* gStatusLock = [[NSObject alloc] init];
NSString* gStatus = @"Apple TV file transfer is off.";
nw_listener_t gListener = nullptr;
std::atomic_bool gRunning(false);
BOOL gSettingsPrepared = NO;
NSString* const kSettingsDefaultsKey = @"TwoShipSettingsJSON";

NSString* ReadStatus() {
    @synchronized(gStatusLock) {
        return [gStatus copy];
    }
}

void WriteStatus(NSString* status) {
    @synchronized(gStatusLock) {
        gStatus = [status copy];
    }
}

NSString* StoragePath() {
    NSArray<NSString*>* paths =
        NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString* caches = paths.firstObject ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"];
    return [caches stringByAppendingPathComponent:@"2Ship 2 Harkinian"];
}

NSString* TransferURL() {
    struct ifaddrs* interfaces = nullptr;
    if (getifaddrs(&interfaces) != 0) {
        return @"http://Apple-TV.local:8080";
    }
    NSString* result = nil;
    for (struct ifaddrs* current = interfaces; current != nullptr; current = current->ifa_next) {
        if (current->ifa_addr == nullptr || current->ifa_addr->sa_family != AF_INET ||
            (current->ifa_flags & IFF_UP) == 0 || (current->ifa_flags & IFF_LOOPBACK) != 0) {
            continue;
        }
        char host[NI_MAXHOST] = {};
        if (getnameinfo(current->ifa_addr, sizeof(struct sockaddr_in), host, sizeof(host),
                        nullptr, 0, NI_NUMERICHOST) == 0) {
            result = [NSString stringWithFormat:@"http://%s:8080", host];
            break;
        }
    }
    freeifaddrs(interfaces);
    return result ?: @"http://Apple-TV.local:8080";
}

bool IsAllowedExtension(NSString* filename, NSString* category) {
    static NSSet<NSString*>* gameDataExtensions = [NSSet setWithArray:@[
        @"o2r", @"otr", @"zip", @"z64", @"n64", @"v64"
    ]];
    static NSSet<NSString*>* modExtensions = [NSSet setWithArray:@[
        @"o2r", @"otr", @"zip"
    ]];
    static NSSet<NSString*>* saveExtensions = [NSSet setWithArray:@[
        @"json", @"png"
    ]];
    static NSSet<NSString*>* presetExtensions = [NSSet setWithObject:@"json"];
    NSString* extension = filename.pathExtension.lowercaseString;
    if ([category isEqualToString:@"roms"]) {
        return [gameDataExtensions containsObject:extension];
    }
    if ([category isEqualToString:@"mods"]) {
        return [modExtensions containsObject:extension];
    }
    if ([category isEqualToString:@"saves"]) {
        return [saveExtensions containsObject:extension];
    }
    if ([category isEqualToString:@"presets"]) {
        return [presetExtensions containsObject:extension];
    }
    return false;
}

NSData* HTTPResponse(NSInteger status, NSString* reason, NSString* contentType, NSData* body) {
    NSString* header = [NSString
        stringWithFormat:@"HTTP/1.1 %ld %@\r\n"
                         "Content-Type: %@\r\n"
                         "Content-Length: %lu\r\n"
                         "Cache-Control: no-store\r\n"
                         "Connection: close\r\n\r\n",
                         (long)status, reason, contentType, (unsigned long)body.length];
    NSMutableData* response = [NSMutableData dataWithData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [response appendData:body];
    return response;
}

NSData* TextResponse(NSInteger status, NSString* reason, NSString* text) {
    return HTTPResponse(status, reason, @"text/plain; charset=utf-8",
                        [text dataUsingEncoding:NSUTF8StringEncoding]);
}

NSData* TransferPage() {
    NSString* html =
        @"<!doctype html><html><head><meta name=viewport content='width=device-width,initial-scale=1'>"
         "<title>2Ship 2 Harkinian Transfer</title><style>"
         "body{font-family:-apple-system,system-ui;background:#211521;color:#fff3ff;max-width:760px;"
         "margin:48px auto;padding:0 24px}h1{color:#dda1d8}.intro{color:#f0c7ec}.card{background:#3b243a;"
         "padding:22px;margin:18px 0;border-radius:16px}.card h2{margin:0 0 6px}.card p{margin:0 0 10px;"
         "color:#e5cde3}input,button{font:inherit;margin:8px 0;padding:12px;border-radius:8px;border:0}"
         "input{display:block;width:calc(100% - 24px);background:#fff;color:#211521}"
         "button{background:#a95b9e;color:white;font-weight:700;cursor:pointer}"
         "progress{display:block;width:100%;height:22px}.status{white-space:pre-wrap;margin-top:12px;"
         "color:#f0c7ec}</style></head><body>"
         "<h1>2 Ship 2 Harkinian</h1><p class=intro>Choose what you want to transfer. Each upload is "
         "placed in the folder 2 Ship reads for that file type.</p>"
         "<div class=card><h2>ROMs &amp; Game Data</h2><p>Legally acquired ROMs and generated O2R/OTR game data.</p>"
         "<input id=romsFile type=file multiple accept='.o2r,.otr,.zip,.z64,.n64,.v64'>"
         "<button onclick=\"uploadFiles('roms','romsFile','romsProgress','romsStatus')\">Upload ROMs</button>"
         "<progress id=romsProgress max=100 value=0></progress><div id=romsStatus class=status>Ready.</div></div>"
         "<div class=card><h2>Mods</h2><p>2 Ship mods and texture packs.</p>"
         "<input id=modsFile type=file multiple accept='.o2r,.otr,.zip'>"
         "<button onclick=\"uploadFiles('mods','modsFile','modsProgress','modsStatus')\">Upload Mods</button>"
         "<progress id=modsProgress max=100 value=0></progress><div id=modsStatus class=status>Ready.</div></div>"
         "<div class=card><h2>Save Files</h2><p>Save-slot JSON files and pictograph PNG files. "
         "Restart 2 Ship after uploading to load them.</p>"
         "<input id=savesFile type=file multiple accept='.json,.png'>"
         "<button onclick=\"uploadFiles('saves','savesFile','savesProgress','savesStatus')\">Upload Saves</button>"
         "<progress id=savesProgress max=100 value=0></progress><div id=savesStatus class=status>Ready.</div></div>"
         "<div class=card><h2>Presets</h2><p>2 Ship preset JSON files.</p>"
         "<input id=presetsFile type=file multiple accept='.json'>"
         "<button onclick=\"uploadFiles('presets','presetsFile','presetsProgress','presetsStatus')\">Upload Presets</button>"
         "<progress id=presetsProgress max=100 value=0></progress><div id=presetsStatus class=status>Ready.</div></div>"
         "<script>async function uploadFiles(category,inputId,progressId,statusId){"
         "const fileInput=document.getElementById(inputId),progressBar=document.getElementById(progressId),"
         "statusText=document.getElementById(statusId),fs=[...fileInput.files];"
         "if(!fs.length){statusText.textContent='Choose a file first.';return;}"
         "for(const f of fs){await new Promise((ok,fail)=>{const x=new XMLHttpRequest();"
         "x.open('PUT','/upload/'+category+'/'+encodeURIComponent(f.name));"
         "x.upload.onprogress=e=>{if(e.lengthComputable)progressBar.value=e.loaded/e.total*100};"
         "x.onload=()=>{statusText.textContent=x.responseText||('Upload failed (HTTP '+x.status+').');"
         "x.status<300?ok():fail(new Error(statusText.textContent))};"
         "x.onerror=()=>{statusText.textContent='Network connection interrupted.';fail(new Error('network'))};"
         "statusText.textContent='Uploading '+f.name+'…';x.send(f)}).catch(()=>{"
         "throw new Error(statusText.textContent)})}"
         "statusText.textContent=category==='saves'?'Upload complete. Restart 2 Ship to load the saves.':"
         "category==='presets'?'Upload complete. Choose Refresh in Settings > Presets on the Apple TV.':"
         "'Upload complete. Choose Rescan on the Apple TV.'}</script></body></html>";
    return HTTPResponse(200, @"OK", @"text/html; charset=utf-8",
                        [html dataUsingEncoding:NSUTF8StringEncoding]);
}

void SendAndClose(nw_connection_t connection, NSData* response) {
    void* bytes = malloc(response.length);
    if (bytes == nullptr) {
        nw_connection_cancel(connection);
        return;
    }
    memcpy(bytes, response.bytes, response.length);
    dispatch_data_t payload =
        dispatch_data_create(bytes, response.length, ServerQueue(), DISPATCH_DATA_DESTRUCTOR_FREE);
    nw_connection_send(connection, payload, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true,
                       ^(nw_error_t error) {
                           nw_connection_cancel(connection);
                       });
}

} // namespace

@interface TwoShipTVOSHTTPConnection : NSObject

@property(nonatomic, strong) nw_connection_t connection;
@property(nonatomic, strong) NSMutableData* pendingHeader;
@property(nonatomic, strong) NSFileHandle* output;
@property(nonatomic, copy) NSString* temporaryPath;
@property(nonatomic, copy) NSString* destinationPath;
@property(nonatomic, copy) NSString* uploadCategory;
@property(nonatomic, copy) NSString* displayName;
@property(nonatomic) uint64_t contentLength;
@property(nonatomic) uint64_t receivedLength;
@property(nonatomic) BOOL headersComplete;
@property(nonatomic) BOOL finished;

- (instancetype)initWithConnection:(nw_connection_t)connection;
- (void)start;

@end

@implementation TwoShipTVOSHTTPConnection

- (instancetype)initWithConnection:(nw_connection_t)connection {
    self = [super init];
    if (self != nil) {
        self.connection = connection;
        self.pendingHeader = [NSMutableData data];
    }
    return self;
}

- (void)start {
    nw_connection_set_queue(self.connection, ServerQueue());
    nw_connection_start(self.connection);
    [self receiveNext];
}

- (void)receiveNext {
    if (self.finished) {
        return;
    }
    TwoShipTVOSHTTPConnection* retainedSelf = self;
    nw_connection_receive(self.connection, 1, 64 * 1024,
                          ^(dispatch_data_t content, nw_content_context_t context,
                            bool isComplete, nw_error_t error) {
                              TwoShipTVOSHTTPConnection* strongSelf = retainedSelf;
                              if (error != nullptr) {
                                  [strongSelf fail:@"Network transfer interrupted." status:500];
                                  return;
                              }
                              if (content != nullptr) {
                                  const void* bytes = nullptr;
                                  size_t length = 0;
                                  dispatch_data_t contiguous =
                                      dispatch_data_create_map(content, &bytes, &length);
                                  (void)contiguous;
                                  if (bytes != nullptr && length > 0) {
                                      [strongSelf consumeBytes:bytes length:length];
                                  }
                              }
                              if (!strongSelf.finished && isComplete) {
                                  if (strongSelf.headersComplete &&
                                      strongSelf.receivedLength == strongSelf.contentLength) {
                                      [strongSelf finishUpload];
                                  } else {
                                      [strongSelf fail:@"Upload ended before the complete file arrived." status:400];
                                  }
                                  return;
                              }
                              [strongSelf receiveNext];
                          });
}

- (void)consumeBytes:(const void*)bytes length:(size_t)length {
    if (!self.headersComplete) {
        [self.pendingHeader appendBytes:bytes length:length];
        if (self.pendingHeader.length > kMaximumHeaderBytes) {
            [self fail:@"Request headers are too large." status:431];
            return;
        }
        NSData* marker = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        NSRange boundary = [self.pendingHeader rangeOfData:marker options:0
                                                    range:NSMakeRange(0, self.pendingHeader.length)];
        if (boundary.location == NSNotFound) {
            return;
        }
        NSUInteger bodyStart = NSMaxRange(boundary);
        NSData* body = bodyStart < self.pendingHeader.length
                           ? [self.pendingHeader subdataWithRange:
                                 NSMakeRange(bodyStart, self.pendingHeader.length - bodyStart)]
                           : [NSData data];
        NSData* headerData =
            [self.pendingHeader subdataWithRange:NSMakeRange(0, boundary.location)];
        self.pendingHeader = nil;
        if (![self parseHeaders:headerData]) {
            return;
        }
        if (body.length > 0) {
            [self consumeBody:body];
        }
        return;
    }
    [self consumeBody:[NSData dataWithBytes:bytes length:length]];
}

- (BOOL)parseHeaders:(NSData*)data {
    NSString* headers = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray<NSString*>* lines = [headers componentsSeparatedByString:@"\r\n"];
    NSArray<NSString*>* request =
        [lines.firstObject componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (request.count < 2) {
        [self fail:@"Malformed HTTP request." status:400];
        return NO;
    }
    NSString* method = request[0].uppercaseString;
    NSString* target = request[1];
    if ([method isEqualToString:@"GET"] && [target isEqualToString:@"/"]) {
        self.finished = YES;
        SendAndClose(self.connection, TransferPage());
        return NO;
    }
    if (![method isEqualToString:@"PUT"] || ![target hasPrefix:@"/upload/"]) {
        [self fail:@"Open the root page and use its Upload button." status:404];
        return NO;
    }

    uint64_t contentLength = 0;
    for (NSString* line in lines) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) {
            continue;
        }
        NSString* key =
            [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceCharacterSet].lowercaseString;
        if ([key isEqualToString:@"content-length"]) {
            contentLength = [[[line substringFromIndex:colon.location + 1]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] longLongValue];
        }
    }
    if (contentLength == 0 || contentLength > kMaximumUploadBytes) {
        [self fail:@"The upload is empty or exceeds the 4 GB transfer limit." status:413];
        return NO;
    }

    NSArray<NSString*>* components = [target componentsSeparatedByString:@"/"];
    if (components.count != 4) {
        [self fail:@"Invalid upload destination." status:400];
        return NO;
    }
    NSString* category = components[2];
    NSString* decoded = [components[3] stringByRemovingPercentEncoding];
    NSString* filename = decoded.lastPathComponent;
    if (filename.length == 0 || ![filename isEqualToString:decoded] ||
        !IsAllowedExtension(filename, category)) {
        [self fail:@"Allowed ROM files: .o2r, .otr, .zip, .z64, .n64, and .v64. "
                    "Allowed mods: .o2r, .otr, and .zip. Allowed saves: .json and .png. "
                    "Allowed presets: .json."
             status:415];
        return NO;
    }

    NSString* directory = StoragePath();
    if ([category isEqualToString:@"mods"]) {
        directory = [directory stringByAppendingPathComponent:@"mods"];
    } else if ([category isEqualToString:@"saves"]) {
        directory = [directory stringByAppendingPathComponent:@"saves"];
    } else if ([category isEqualToString:@"presets"]) {
        directory = [directory stringByAppendingPathComponent:@"presets"];
    } else if (![category isEqualToString:@"roms"]) {
        [self fail:@"Invalid upload category." status:400];
        return NO;
    }
    NSError* directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                   withIntermediateDirectories:YES attributes:nil
                                                        error:&directoryError]) {
        [self fail:[@"Apple TV storage could not be prepared: "
                     stringByAppendingString:directoryError.localizedDescription ?: @"unknown error"]
             status:500];
        return NO;
    }

    self.contentLength = contentLength;
    self.uploadCategory = category;
    self.destinationPath = [directory stringByAppendingPathComponent:filename];
    self.displayName = filename;
    self.temporaryPath = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@".upload-%@", NSUUID.UUID.UUIDString]];
    if (![[NSFileManager defaultManager] createFileAtPath:self.temporaryPath contents:nil attributes:nil]) {
        [self fail:@"The temporary upload file could not be created." status:500];
        return NO;
    }
    self.output = [NSFileHandle fileHandleForWritingAtPath:self.temporaryPath];
    if (self.output == nil) {
        [self fail:@"The uploaded file could not be opened for writing." status:500];
        return NO;
    }
    self.headersComplete = YES;
    WriteStatus([NSString stringWithFormat:@"Receiving %@ — 0%%", filename]);
    return YES;
}

- (void)consumeBody:(NSData*)data {
    if (self.finished || data.length == 0) {
        return;
    }
    uint64_t remaining = self.contentLength - self.receivedLength;
    NSUInteger accepted = (NSUInteger)MIN((uint64_t)data.length, remaining);
    @try {
        [self.output writeData:
            accepted == data.length ? data : [data subdataWithRange:NSMakeRange(0, accepted)]];
    } @catch (NSException* exception) {
        [self fail:@"Apple TV storage ran out of space or became unavailable." status:507];
        return;
    }
    self.receivedLength += accepted;
    NSInteger percent = (NSInteger)((self.receivedLength * 100) / self.contentLength);
    WriteStatus([NSString stringWithFormat:@"Receiving %@ — %ld%%", self.displayName, (long)percent]);
    if (self.receivedLength == self.contentLength) {
        [self finishUpload];
    }
}

- (void)finishUpload {
    if (self.finished) {
        return;
    }
    self.finished = YES;
    [self.output closeFile];
    self.output = nil;
    NSFileManager* files = [NSFileManager defaultManager];
    NSError* error = nil;
    BOOL installed = NO;
    if ([files fileExistsAtPath:self.destinationPath]) {
        installed = [files replaceItemAtURL:[NSURL fileURLWithPath:self.destinationPath]
                              withItemAtURL:[NSURL fileURLWithPath:self.temporaryPath]
                             backupItemName:nil options:0 resultingItemURL:nil error:&error];
    } else {
        installed = [files moveItemAtPath:self.temporaryPath toPath:self.destinationPath error:&error];
    }
    if (!installed) {
        [files removeItemAtPath:self.temporaryPath error:nil];
        WriteStatus([@"Upload could not be installed: "
            stringByAppendingString:error.localizedDescription ?: @"unknown storage error"]);
        SendAndClose(self.connection, TextResponse(500, @"Internal Server Error",
                                                   @"The file arrived but could not be installed."));
        return;
    }
    BOOL isSave = [self.uploadCategory isEqualToString:@"saves"];
    BOOL isPreset = [self.uploadCategory isEqualToString:@"presets"];
    NSString* instruction = isSave
                                ? @"Restart 2 Ship to load the uploaded saves."
                                : (isPreset ? @"Choose Refresh in Settings > Presets."
                                            : @"Choose Rescan in 2 Ship to load the uploaded files.");
    WriteStatus([NSString stringWithFormat:@"%@ uploaded. %@", self.displayName, instruction]);
    SendAndClose(self.connection, TextResponse(201, @"Created",
                                               [@"Upload complete. " stringByAppendingString:instruction]));
}

- (void)fail:(NSString*)message status:(NSInteger)status {
    if (self.finished) {
        return;
    }
    self.finished = YES;
    [self.output closeFile];
    self.output = nil;
    if (self.temporaryPath != nil) {
        [[NSFileManager defaultManager] removeItemAtPath:self.temporaryPath error:nil];
    }
    WriteStatus(message);
    SendAndClose(self.connection, TextResponse(status, @"Upload Error", message));
}

@end

extern "C" void TwoShipTVOSFileServer_Start(void) {
    WriteStatus([NSString stringWithFormat:@"Starting Apple TV file transfer… Open %@", TransferURL()]);
    dispatch_async(ServerQueue(), ^{
        if (gListener != nullptr) {
            return;
        }
        nw_parameters_t parameters =
            nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                            NW_PARAMETERS_DEFAULT_CONFIGURATION);
        gListener = nw_listener_create_with_port("8080", parameters);
        if (gListener == nullptr) {
            WriteStatus(@"Could not start Apple TV file transfer.");
            return;
        }
        nw_advertise_descriptor_t descriptor =
            nw_advertise_descriptor_create_bonjour_service("2Ship 2 Harkinian", "_2ship._tcp", nullptr);
        nw_listener_set_advertise_descriptor(gListener, descriptor);
        nw_listener_set_queue(gListener, ServerQueue());
        nw_listener_set_state_changed_handler(gListener, ^(nw_listener_state_t state, nw_error_t error) {
            if (state == nw_listener_state_ready) {
                gRunning.store(true);
                WriteStatus([NSString stringWithFormat:
                    @"On a phone or computer on this network, open %@", TransferURL()]);
            } else if (state == nw_listener_state_failed) {
                gRunning.store(false);
                WriteStatus(@"Apple TV file transfer failed to start.");
                nw_listener_cancel(gListener);
                gListener = nullptr;
            } else if (state == nw_listener_state_cancelled) {
                gRunning.store(false);
                gListener = nullptr;
            }
        });
        nw_listener_set_new_connection_handler(gListener, ^(nw_connection_t connection) {
            TwoShipTVOSHTTPConnection* handler =
                [[TwoShipTVOSHTTPConnection alloc] initWithConnection:connection];
            [handler start];
        });
        nw_listener_start(gListener);
    });
}

extern "C" void TwoShipTVOSFileServer_Stop(void) {
    dispatch_async(ServerQueue(), ^{
        if (gListener != nullptr) {
            nw_listener_cancel(gListener);
        }
        gRunning.store(false);
        WriteStatus(@"Apple TV file transfer is off.");
    });
}

extern "C" int TwoShipTVOSFileServer_IsRunning(void) {
    return gRunning.load() ? 1 : 0;
}

extern "C" void TwoShipTVOSFileServer_GetStatus(char* buffer, size_t bufferSize) {
    if (buffer == nullptr || bufferSize == 0) {
        return;
    }
    const char* status = ReadStatus().UTF8String ?: "Apple TV file transfer is unavailable.";
    std::strncpy(buffer, status, bufferSize - 1);
    buffer[bufferSize - 1] = '\0';
}

extern "C" void TwoShipTVOS_GetNativeRightStick(float* rightX, float* rightY) {
    if (rightX == nullptr || rightY == nullptr) {
        return;
    }

    *rightX = 0.0f;
    *rightY = 0.0f;
    for (GCController* controller in GCController.controllers) {
        GCExtendedGamepad* gamepad = controller.extendedGamepad;
        if (gamepad == nil) {
            continue;
        }
        const float x = gamepad.rightThumbstick.xAxis.value;
        const float y = gamepad.rightThumbstick.yAxis.value;
        if (fabsf(x) > fabsf(*rightX)) {
            *rightX = x;
        }
        if (fabsf(y) > fabsf(*rightY)) {
            *rightY = y;
        }
    }
}

extern "C" int TwoShipApple_GetNativeControllerGyro(float* gyroX, float* gyroY, float* gyroZ) {
    if (gyroX == nullptr || gyroY == nullptr || gyroZ == nullptr) {
        return 0;
    }

    *gyroX = 0.0f;
    *gyroY = 0.0f;
    *gyroZ = 0.0f;
    for (GCController* controller in GCController.controllers) {
        GCMotion* motion = controller.motion;
        if (controller.extendedGamepad == nil || motion == nil || !motion.hasRotationRate) {
            continue;
        }
        if (motion.sensorsRequireManualActivation) {
            motion.sensorsActive = YES;
        }
        const GCRotationRate rate = motion.rotationRate;
        *gyroX = (float)rate.x;
        *gyroY = (float)rate.y;
        *gyroZ = (float)rate.z;
        return 1;
    }
    return 0;
}

extern "C" void TwoShipTVOS_GetNativeControllerStatus(char* buffer, size_t bufferSize) {
    if (buffer == nullptr || bufferSize == 0) {
        return;
    }

    NSMutableArray<NSString*>* lines = [NSMutableArray array];
    NSUInteger index = 0;
    for (GCController* controller in GCController.controllers) {
        GCExtendedGamepad* gamepad = controller.extendedGamepad;
        NSString* name = controller.vendorName ?: controller.productCategory ?: @"Unknown controller";
        if (gamepad == nil) {
            [lines addObject:[NSString stringWithFormat:@"%lu. %@ — no extended gamepad profile",
                                                       (unsigned long)++index, name]];
            continue;
        }
        GCMotion* motion = controller.motion;
        [lines addObject:[NSString
            stringWithFormat:@"%lu. %@ — L(%.2f, %.2f) R(%.2f, %.2f) R3:%d Gyro:%@",
                             (unsigned long)++index, name,
                             gamepad.leftThumbstick.xAxis.value, gamepad.leftThumbstick.yAxis.value,
                             gamepad.rightThumbstick.xAxis.value, gamepad.rightThumbstick.yAxis.value,
                             gamepad.rightThumbstickButton.isPressed ? 1 : 0,
                             motion != nil && motion.hasRotationRate ? @"yes" : @"no"]];
    }
    if (lines.count == 0) {
        [lines addObject:@"Apple GameController reports no connected controllers."];
    }
    const char* status = [lines componentsJoinedByString:@"\n"].UTF8String;
    std::strncpy(buffer, status ?: "Controller diagnostics unavailable.", bufferSize - 1);
    buffer[bufferSize - 1] = '\0';
}

extern "C" void TwoShipTVOS_PrepareSettingsJSON(const char* workingPath) {
    if (workingPath == nullptr) {
        return;
    }
    @synchronized(gStatusLock) {
        if (gSettingsPrepared) {
            return;
        }
        gSettingsPrepared = YES;
    }

    NSString* path = [NSString stringWithUTF8String:workingPath];
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSData* persisted = [defaults dataForKey:kSettingsDefaultsKey];
    if (persisted.length > 0) {
        [persisted writeToFile:path options:NSDataWritingAtomic error:nil];
        return;
    }

    NSData* existing = [NSData dataWithContentsOfFile:path];
    if (existing.length > 0) {
        [defaults setObject:existing forKey:kSettingsDefaultsKey];
        [defaults synchronize];
    }
}

extern "C" void TwoShipTVOS_PersistSettingsJSON(const char* jsonBytes, size_t jsonLength) {
    if (jsonBytes == nullptr || jsonLength == 0) {
        return;
    }
    NSData* data = [NSData dataWithBytes:jsonBytes length:jsonLength];
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:data forKey:kSettingsDefaultsKey];
    [defaults synchronize];
}
