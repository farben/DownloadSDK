//
//  DownloadSession.m
//  DownloadManager
//
//  Created by liubo on 2018/4/18.
//  Copyright © 2018年 Person. All rights reserved.
//  Github: https://github.com/gitliubo/DownloadSDK.git
//

#import "DownloadSession.h"


#ifdef DEBUG//NSLog(__VA_ARGS__)
#define YCLog(...) NSLog(__VA_ARGS__)
#else
#define YCLog(...)
#endif

static NSString * const kIsAllowCellar = @"kIsAllowCellar";
@interface DownloadSession ()<NSURLSessionDownloadDelegate>

/**正在下载的task*/
@property (nonatomic, strong) NSMutableDictionary *downloadTasks;
/**后台下载回调的handlers，所有的下载任务全部结束后调用*/
@property (nonatomic, copy) CompletedHandler completedHandler;
@property (nonatomic, strong, readonly) NSURLSession *session;
/**重新创建sessio标记位*/
@property (nonatomic, assign) BOOL isNeedCreateSession;

@property (strong, nonatomic) dispatch_queue_t downloadQueue;

@end

@implementation DownloadSession


static DownloadSession *_instance;

- (void)dealloc{
    self.downloadQueue = nil;
    self.downloadTasks = nil;
}

+ (instancetype)downloadSession {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[self alloc] init];
    });
    return _instance;
}


- (instancetype)init {
    if (self = [super init]) {
        //初始化
        _session = [self getDownloadURLSession];
        _maxTaskCount = 1;
        _downloadVersion = @"1.2.1";
        self.downloadQueue = dispatch_queue_create("YCDownloadQueue", DISPATCH_QUEUE_SERIAL);

        //获取保存在本地的数据是否为空，为空则初始化
        _downloadTasks = [NSKeyedUnarchiver unarchiveObjectWithFile:[self getArchiverPath]];
        if(!_downloadTasks) _downloadTasks = [NSMutableDictionary dictionary];
        
        [self compatiableDownloadData];
        
        //获取背景session正在运行的(app重启，或者闪退会有任务)
        NSMutableDictionary *dictM = [self.session valueForKey:@"tasks"];
        [dictM enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
            DownloadTask *task = [self getDownloadTaskWithUrl:[DownloadTask getURLFromTask:obj]];
            if(!task){
                [obj cancel];
            }else{
                task.downloadTask = obj;
            }
        }];
        
        if (dictM.count>0) {
            //app重启，或者闪退的任务全部暂停,Xcode连接重启app
            [self pauseAllDownloadTask];
            YCLog(@"app start default pause all bg runing task! task count: %zd", dictM.count);
            //waiting async pause task callback
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self detectAllCacheFileSize];
            });
        }
        
    }
    return self;
}

- (void)compatiableDownloadData {
    //TODO: compatible version 1.0.0
    NSString *downloadingDataPath = [self getArchiverPathIsDownloaded:false];
    NSString *downloadedDataPath = [self getArchiverPathIsDownloaded:true];
    NSMutableDictionary *downloadingDictM = [NSKeyedUnarchiver unarchiveObjectWithFile:downloadingDataPath];
    NSMutableDictionary *downloadedDictM = [NSKeyedUnarchiver unarchiveObjectWithFile:downloadedDataPath];
    
    [downloadingDictM enumerateKeysAndObjectsUsingBlock:^(NSString *  _Nonnull key, DownloadTask *  _Nonnull obj, BOOL * _Nonnull stop) {
        [self.downloadTasks setValue:obj forKey:[DownloadTask taskIdForUrl:key fileId:nil]];
    }];
    
    [downloadedDictM enumerateKeysAndObjectsUsingBlock:^(NSString *  _Nonnull key, DownloadTask *   _Nonnull obj, BOOL * _Nonnull stop) {
        [self.downloadTasks setValue:obj forKey:[DownloadTask taskIdForUrl:key fileId:nil]];
    }];
    
    [[NSFileManager defaultManager] removeItemAtPath:downloadingDataPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:downloadedDataPath error:nil];
    [self saveDownloadStatus];
}

- (NSURLSession *)getDownloadURLSession {
    
    NSURLSession *session = nil;
    NSString *identifier = [self backgroundSessionIdentifier];
    NSURLSessionConfiguration* sessionConfig = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:identifier];
    sessionConfig.allowsCellularAccess = [[NSUserDefaults standardUserDefaults] boolForKey:kIsAllowCellar];
    
    session = [NSURLSession sessionWithConfiguration:sessionConfig
                                            delegate:self
                                       delegateQueue:[NSOperationQueue mainQueue]];
    
    return session;
}

- (NSString *)backgroundSessionIdentifier {
    NSString *bundleId = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleIdentifier"];
    NSString *identifier = [NSString stringWithFormat:@"%@.BackgroundSession", bundleId];
    return identifier;
}

- (void)recreateSession {
    
    _session = [self getDownloadURLSession];
    YCLog(@"recreate Session success");
    //恢复正在下载的task状态
    [self.downloadTasks enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
        DownloadTask *task = obj;
        task.downloadTask = nil;
        if (task.needToRestart) {
            task.needToRestart = false;
            [self resumeDownloadTask:task];
        }
    }];
}


-(void)setMaxTaskCount:(NSInteger)maxTaskCount {
    if (maxTaskCount>3) {
        _maxTaskCount = 3;
    }else if(maxTaskCount <= 0){
        _maxTaskCount = 1;
    }else{
        _maxTaskCount = maxTaskCount;
    }
}

- (NSInteger)currentTaskCount {
    NSMutableDictionary *dictM = [self.session valueForKey:@"tasks"];
    __block NSInteger count = 0;
    [dictM enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
        NSURLSessionTask *task = obj;
        if (task.state == NSURLSessionTaskStateRunning) {
            count++;
        }
    }];
    return count;
}

#pragma mark - public

- (DownloadTask *)startDownloadWithUrl:(NSString *)downloadURLString fileId:(NSString *)fileId delegate:(id<DownloadTaskDelegate>)delegate{
    if (downloadURLString.length == 0)  return nil;
    //判断是否是下载完成的任务
    DownloadTask *task = [self.downloadTasks valueForKey:[DownloadTask taskIdForUrl:downloadURLString fileId:fileId]];
    if ([self detectDownloadTaskIsFinished:task]) {
        task.delegate = delegate;
        [self downloadStatusChanged:kDownloadStatusFinished task:task];
        return task;
    }
    if (!task) {
        //判断任务的个数，如果达到最大值则返回，回调等待
        if([self currentTaskCount] >= self.maxTaskCount){
            //创建任务，让其处于等待状态
            task = [self createDownloadTaskItemWithUrl:downloadURLString fileId:fileId delegate:delegate];
            [self downloadStatusChanged:kDownloadStatusWaiting task:task];
            return task;
        }else {
            //开始下载
            return [self startNewTaskWithUrl:downloadURLString fileId:fileId delegate:delegate];
        }
    }else{
        task.delegate = delegate;
        [self resumeDownloadTask:task];
        return task;
    }
}


- (void)pauseDownloadWithTask:(DownloadTask *)task {
    [self pauseDownloadTask:task];
}

- (void)resumeDownloadWithTask:(DownloadTask *)task{
    [self resumeDownloadTask:task];
}

- (void)stopDownloadWithTask:(DownloadTask *)task{
    [self stopDownloadWithTaskId:task.taskId];
}

- (void)pauseDownloadWithTaskId:(NSString *)taskId {
    DownloadTask *task = [self.downloadTasks valueForKey:taskId];
    //TODO: compatiable 1.0.0
    if(!task){
        task = [self compatibleOldTaskId:taskId];
    }
    //TODO: compatiable 1.0.0 end
    [self pauseDownloadTask:task];
}

- (void)resumeDownloadWithTaskId:(NSString *)taskId{
    DownloadTask *task = [self.downloadTasks valueForKey:taskId];
    //TODO: compatiable 1.0.0
    if(!task){
        task = [self compatibleOldTaskId:taskId];
    }
    //TODO: compatiable 1.0.0 end
    [self resumeDownloadTask:task];
}

- (void)stopDownloadWithTaskId:(NSString *)taskId {
    __weak DownloadSession *weakSelf = self;
    dispatch_async(self.downloadQueue, ^{
        DownloadTask *task = [weakSelf.downloadTasks valueForKey:taskId];
        //TODO: compatiable 1.0.0
        if(!task){
            task = [weakSelf compatibleOldTaskId:taskId];
        }
        //TODO: compatiable 1.0.0 end
        if (task && [[NSFileManager defaultManager] fileExistsAtPath:task.savePath]) {
            [[NSFileManager defaultManager] removeItemAtPath:task.savePath error:nil];
        }
        [task.downloadTask cancel];
        if(task.taskId.length>0)[weakSelf.downloadTasks removeObjectForKey:task.taskId];
        [weakSelf saveDownloadStatus];
        [weakSelf startNextDownloadTask];
    });
}

- (void)pauseAllDownloadTask{
    __weak DownloadSession *weakSelf = self;
    dispatch_async(self.downloadQueue, ^{
        [weakSelf.downloadTasks enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, DownloadTask * _Nonnull obj, BOOL * _Nonnull stop) {
            if(obj.downloadStatus == kDownloadStatusDownloading){
                obj.noNeedToStartNext = true;
                [weakSelf pauseDownloadTask:obj];
            }
            else if (obj.downloadStatus == kDownloadStatusWaiting){
                [weakSelf downloadStatusChanged:kDownloadStatusPaused task:obj];
            }
        }];
    }) ;
}

- (void)resumeAllDownloadTask {
    
}

- (void)removeAllCache {
    __weak DownloadSession *weakSelf = self;
    dispatch_async(self.downloadQueue, ^{
        [weakSelf pauseAllDownloadTask];
        [weakSelf.downloadTasks enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, DownloadTask *  _Nonnull obj, BOOL * _Nonnull stop) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:obj.savePath]) {
                [[NSFileManager defaultManager] removeItemAtPath:obj.savePath error:nil];
            }
        }];
        [weakSelf.downloadTasks removeAllObjects];
        [weakSelf saveDownloadStatus];
    });
}

- (DownloadTask *)taskForTaskId:(NSString *)taskId {
    DownloadTask *task = [self.downloadTasks valueForKey:taskId];
    //TODO: compatiable 1.0.0
    if(!task){
        task = [self compatibleOldTaskId:taskId];
    }
    
    return task;
}

- (void)allowsCellularAccess:(BOOL)isAllow {
    
    [[NSUserDefaults standardUserDefaults] setBool:isAllow forKey:kIsAllowCellar];
    [self.downloadTasks enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
        DownloadTask *task = obj;
        if (task.downloadTask.state == NSURLSessionTaskStateRunning) {
            task.needToRestart = true;
            task.noNeedToStartNext = true;
            [self pauseDownloadTask:task];
        }
    }];
    
    [_session invalidateAndCancel];
    self.isNeedCreateSession = true;
}

- (BOOL)isAllowsCellularAccess {
    
    return [[NSUserDefaults standardUserDefaults] boolForKey:kIsAllowCellar];
}

-(void)addCompletionHandler:(CompletedHandler)handler identifier:(NSString *)identifier{
    if ([[self backgroundSessionIdentifier] isEqualToString:identifier]) {
        self.completedHandler = handler;
    }
}

#pragma mark - private
- (DownloadTask *)startNewTaskWithUrl:(NSString *)downloadURLString fileId:(NSString *)fileId delegate:(id<DownloadTaskDelegate>)delegate{
    NSURL *downloadURL = [NSURL URLWithString:downloadURLString];
    NSURLRequest *request = [NSURLRequest requestWithURL:downloadURL];
    NSURLSessionDownloadTask *downloadTask = [self.session downloadTaskWithRequest:request];
    DownloadTask *task = [self createDownloadTaskItemWithUrl:downloadURLString fileId:fileId delegate:delegate];
    task.downloadTask = downloadTask;
    [downloadTask resume];
    [self downloadStatusChanged:kDownloadStatusDownloading task:task];
    
    return task;
}

- (DownloadTask *)createDownloadTaskItemWithUrl:(NSString *)downloadURLString fileId:(NSString *)fileId delegate:(id<DownloadTaskDelegate>)delegate{
    DownloadTask *task = [DownloadTask taskWithUrl:downloadURLString fileId:fileId delegate:delegate];
    task.delegate = delegate;
    [self.downloadTasks setObject:task forKey:task.taskId];
    [self downloadStatusChanged:kDownloadStatusWaiting task:task];
    
    return task;
}

- (void)pauseDownloadTask:(DownloadTask *)task{
    //暂停逻辑在这里处理 - (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
    if (task.downloadTask) {
        [task.downloadTask cancelByProducingResumeData:^(NSData * resumeData) { }];
    } else {
        task.downloadStatus = kDownloadStatusPaused;
    }
}

- (void)resumeDownloadTask:(DownloadTask *)task {
    if(!task) return;
    __weak DownloadSession *weakSelf = self;
    dispatch_async(self.downloadQueue, ^{
        if ([weakSelf detectDownloadTaskIsFinished:task]) {
            [weakSelf downloadStatusChanged:kDownloadStatusFinished task:task];
            return;
        }
        
        if (([weakSelf currentTaskCount] >= weakSelf.maxTaskCount) && task.downloadStatus != kDownloadStatusDownloading) {
            [weakSelf downloadStatusChanged:kDownloadStatusWaiting task:task];
            return;
        }
        
        NSData *data = task.resumeData;
        if (data.length > 0) {
            if(task.downloadTask && task.downloadTask.state == NSURLSessionTaskStateRunning){
                [weakSelf downloadStatusChanged:kDownloadStatusDownloading task:task];
                return;
            }
            NSURLSessionDownloadTask *downloadTask = nil;
            @try {
                downloadTask = [YCResumeData downloadTaskWithCorrectResumeData:data urlSession:weakSelf.session];
            } @catch (NSException *exception) {
                [weakSelf downloadStatusChanged:kDownloadStatusFailed task:task];
                return;
            }
            task.downloadTask = downloadTask;
            [downloadTask resume];
            task.resumeData = nil;
            [weakSelf downloadStatusChanged:kDownloadStatusDownloading task:task];
            
        }else{
            
            if (!task.downloadTask || task.downloadTask.state == NSURLSessionTaskStateCompleted || task.downloadTask.state == NSURLSessionTaskStateCanceling) {
                [task.downloadTask cancel];
                NSURL *downloadURL = [NSURL URLWithString:task.downloadURL];
                NSURLRequest *request = [NSURLRequest requestWithURL:downloadURL];
                NSURLSessionDownloadTask *downloadTask = [weakSelf.session downloadTaskWithRequest:request];
                task.downloadTask = downloadTask;
            }
            [task.downloadTask resume];
            [weakSelf downloadStatusChanged:kDownloadStatusDownloading task:task];
        }
    });
}

- (void)startNextDownloadTask {
    __weak DownloadSession *weakSelf = self;
    dispatch_async(self.downloadQueue, ^{
        if ([weakSelf currentTaskCount] < weakSelf.maxTaskCount) {
            [weakSelf.downloadTasks enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
                DownloadTask *task = obj;
                if ((!task.downloadTask || task.downloadTask.state != NSURLSessionTaskStateRunning) && task.downloadStatus == kDownloadStatusWaiting) {
                    [weakSelf resumeDownloadTask:task];
                }
            }];
        }
    });
}


- (void)downloadStatusChanged:(DownloadStatus)status task:(DownloadTask *)task{
    
    task.downloadStatus = status;
    [self saveDownloadStatus];
    switch (status) {
        case kDownloadStatusWaiting:
            break;
        case kDownloadStatusDownloading:
            break;
        case kDownloadStatusPaused:
            break;
        case kDownloadStatusFailed:
            break;
        case kDownloadStatusFinished:
            [self startNextDownloadTask];
            break;
        default:
            break;
    }
    
    if ([task.delegate respondsToSelector:@selector(downloadStatusChanged:downloadTask:)]) {
        [task.delegate downloadStatusChanged:status downloadTask:task];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:kDownloadStatusChangedNoti object:nil];
    
    //等task delegate方法执行完成后去判断该逻辑
    //URLSessionDidFinishEventsForBackgroundURLSession 方法在后台执行一次，所以在此判断执行completedHandler
    if (status == kDownloadStatusFinished) {
        if ([self allTaskFinised]) {
            [[NSNotificationCenter defaultCenter] postNotificationName:kDownloadAllTaskFinishedNoti object:nil];
            //所有的任务执行结束之后调用completedHanlder
            if (self.completedHandler) {
                YCLog(@"completedHandler");
                self.completedHandler();
                self.completedHandler = nil;
            }
        }
    }
}

- (BOOL)allTaskFinised {
    if (self.downloadTasks.count == 0) return true;
    __block BOOL isFinished = true;
    [self.downloadTasks enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
        DownloadTask *task = obj;
        if (task.downloadStatus == kDownloadStatusWaiting || task.downloadStatus == kDownloadStatusDownloading) {
            isFinished = false;
            *stop = true;
        }
    }];
    
    return isFinished;
}

- (void)saveDownloadStatus {
    [NSKeyedArchiver archiveRootObject:self.downloadTasks toFile:[self getArchiverPath]];
}

//TODO: compatible old version 1.0.0
- (NSString *)getArchiverPathIsDownloaded:(BOOL)isDownloaded {
    NSString *saveDir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, true).firstObject;
    saveDir = [saveDir stringByAppendingPathComponent:@"Download"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:saveDir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:saveDir withIntermediateDirectories:true attributes:nil error:nil];
    }
    saveDir = isDownloaded ? [saveDir stringByAppendingPathComponent:@"Downloaded.data"] : [saveDir stringByAppendingPathComponent:@"Downloading.data"];
    return saveDir;
}

- (DownloadTask *)compatibleOldTaskId:(NSString *)taskId {
    __block DownloadTask *oldTask = nil;
    [self.downloadTasks enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, DownloadTask *  _Nonnull obj, BOOL * _Nonnull stop) {
        if([obj.downloadURL isEqualToString:taskId]){
            oldTask = obj;
            *stop = true;
        }
    }];
    return oldTask;
}


- (NSString *)getArchiverPath{
    NSString *saveDir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, true).firstObject;
    saveDir = [saveDir stringByAppendingPathComponent:@"YCDownload"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:saveDir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:saveDir withIntermediateDirectories:true attributes:nil error:nil];
    }
    saveDir = [saveDir stringByAppendingPathComponent:@"YCDownload.db"];
    return saveDir;
}

- (void)detectAllCacheFileSize{
    
    [self.downloadTasks enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, DownloadTask *  _Nonnull task, BOOL * _Nonnull stop) {
        if(task.downloadStatus == kDownloadStatusPaused || task.downloadStatus == kDownloadStatusFailed){
            //如果存在取最后一个，基本只有1个
            NSArray *temps = [self getTmpPathsWithTask:task];
            if(temps.count>0){
                NSString *tmpPath = temps.lastObject;
                task.downloadedSize = [self fileSizeWithPath:tmpPath];
            }
        }
    }];
    [self saveDownloadStatus];
}

- (NSInteger)fileSizeWithPath:(NSString *)path {
    if(![[NSFileManager defaultManager] fileExistsAtPath:path]) return 0;
    NSDictionary *dic = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return dic ? (NSInteger)[dic fileSize] : 0;
}

- (BOOL)detectDownloadTaskIsFinished:(DownloadTask *)task {
    if (!task) return false;
    if(task.downloadFinished) return true;
    NSArray *tmpPaths = [self getTmpPathsWithTask:task];
    __block BOOL isFinished = false;
    [tmpPaths enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        NSString *path = obj;
        NSInteger fileSize = [self fileSizeWithPath:path];
        if (fileSize>0 && fileSize == task.fileSize) {
            [[NSFileManager defaultManager] moveItemAtPath:path toPath:task.savePath error:nil];
            isFinished = true;
            task.downloadStatus = kDownloadStatusFinished;
            *stop = true;
        }
    }];
    
    return isFinished;
}

- (NSArray *)getTmpPathsWithTask:(DownloadTask *)task {
    
    if(!task) return nil;
    NSMutableArray *tmpPaths = [NSMutableArray array];
    NSFileManager *fileMgr = [NSFileManager defaultManager];
    //download finish callback -> locationString
    if (task.tempPath.length > 0 && [fileMgr fileExistsAtPath:task.tempPath]) {
        [tmpPaths addObject:task.tempPath];
    }else{
        task.tempPath = nil;
    }
    if (task.tmpName.length > 0) {
        NSString *downloadPath = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, true).firstObject;
        NSString *bundleId = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleIdentifier"];
        //1. 系统正在下载的文件tmp文件存储路径和部分异常的tmp文件(回调失败)
        downloadPath = [downloadPath stringByAppendingPathComponent: [NSString stringWithFormat:@"/com.apple.nsurlsessiond/Downloads/%@/", bundleId]];
        downloadPath = [downloadPath stringByAppendingPathComponent:task.tmpName];
        if([fileMgr fileExistsAtPath:downloadPath]) [tmpPaths addObject:downloadPath];
        
        //2. 暂停下载后，系统从 downloadPath 目录移动到此
        NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:task.tmpName];
        if([fileMgr fileExistsAtPath:tmpPath]) [tmpPaths addObject:tmpPath];
    }
    if(tmpPaths.count == 0) task.tmpName = nil;
    return tmpPaths;
    
}


- (DownloadTask *)getDownloadTaskWithUrl:(NSString *)downloadUrl{
    NSMutableDictionary *tasks = self.downloadTasks ;
    __block DownloadTask *task = nil;
    [tasks enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
        DownloadTask *dTask = obj;
        if ([dTask.downloadURL isEqualToString:downloadUrl]) {
            task = dTask;
            *stop = true;
        }
    }];
    
    return task;
}

#pragma mark -  NSURLSessionDelegate
//将一个后台session作废完成后的回调，用来切换是否允许使用蜂窝煤网络，重新创建session
- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(nullable NSError *)error {
    
    if (self.isNeedCreateSession) {
        self.isNeedCreateSession = false;
        [self recreateSession];
    }
}

//如果appDelegate实现下面的方法，后台下载完成时，会自动唤醒启动app。如果不实现，那么后台下载完成不唤醒，用户手动启动会调用相关回调方法
//-[AppDelegate application:handleEventsForBackgroundURLSession:completionHandler:]
//后台唤醒调用顺序： appdelegate ——> didFinishDownloadingToURL  ——> URLSessionDidFinishEventsForBackgroundURLSession
//手动启动调用顺序: didFinishDownloadingToURL  ——> URLSessionDidFinishEventsForBackgroundURLSession
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    
    YCLog(@"%s", __func__);
    
    NSString *locationString = [location path];
    NSError *error;
    
    NSString *downloadUrl = [DownloadTask getURLFromTask:downloadTask];
    DownloadTask *task = [self getDownloadTaskWithUrl:downloadUrl];
    if(!task){
        YCLog(@"download finished , item nil error!!!! url: %@", downloadUrl);
        return;
    }
    task.tempPath = locationString;
    NSInteger fileSize =[self fileSizeWithPath:locationString];
    //校验文件大小
    BOOL isCompltedFile = (fileSize>0) && (fileSize == task.fileSize);
    //文件大小不对，回调失败 ios11 多次暂停继续会出现文件大小不对的情况
    if (!isCompltedFile) {
        [self downloadStatusChanged:kDownloadStatusFailed task:task];
        //删除异常的缓存文件
        [[NSFileManager defaultManager] removeItemAtPath:locationString error:nil];
        return;
    }
    task.downloadedSize = task.fileSize;
    [[NSFileManager defaultManager] moveItemAtPath:locationString toPath:task.savePath error:&error];
    
    if (task.downloadURL.length != 0) {
        [self.downloadTasks setObject:task forKey:task.taskId];
    }
    [self downloadStatusChanged:kDownloadStatusFinished task:task];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes {
    
    //NSLog(@"fileOffset:%lld expectedTotalBytes:%lld",fileOffset,expectedTotalBytes);
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    DownloadTask *task = [self getDownloadTaskWithUrl:[DownloadTask getURLFromTask:downloadTask]];
    task.downloadedSize = (NSInteger)totalBytesWritten;
    if (task.fileSize == 0)  {
        [task updateTask];
        if ([task.delegate respondsToSelector:@selector(downloadCreated:)]) {
            [task.delegate downloadCreated:task];
        }
        [self saveDownloadStatus];
    }
    
    if([task.delegate respondsToSelector:@selector(downloadProgress:downloadedSize:fileSize:)]){
        [task.delegate downloadProgress:task downloadedSize:task.downloadedSize fileSize:task.fileSize];
    }
    
    //    NSString *url = downloadTask.response.URL.absoluteString;
    //    YCLog(@"downloadURL: %@  downloadedSize: %zd totalSize: %zd  progress: %f", url, task.downloadedSize, task.fileSize, (float)task.downloadedSize / task.fileSize);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    
    //YCLog(@"willPerformHTTPRedirection ------> %@",response);
}

//后台下载完成后调用。在执行 URLSession:downloadTask:didFinishDownloadingToURL: 之后调用
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    //YCLog(@"%s", __func__);
    
}

/*
 * 该方法下载成功和失败都会回调，只是失败的是error是有值的，
 * 在下载失败时，error的userinfo属性可以通过NSURLSessionDownloadTaskResumeData
 * 这个key来取到resumeData(和上面的resumeData是一样的)，再通过resumeData恢复下载
 */
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    DownloadTask *yctask = [self getDownloadTaskWithUrl:[DownloadTask getURLFromTask:task]];
    if (error) {
        // check whether resume data are available
        NSData *resumeData = [error.userInfo objectForKey:NSURLSessionDownloadTaskResumeData];
        if (resumeData) {
            
            float deviceVersion = [[[UIDevice currentDevice] systemVersion] floatValue];
            if (deviceVersion >= 11.0f && deviceVersion < 11.2f) {
                //修正iOS11 多次暂停继续 文件大小不对的问题
                resumeData = [YCResumeData cleanResumeData:resumeData];
            }
            //通过之前保存的resumeData，获取断点的NSURLSessionTask，调用resume恢复下载
            yctask.resumeData = resumeData;
            id resumeDataObj = [NSPropertyListSerialization propertyListWithData:resumeData options:0 format:0 error:nil];
            if ([resumeDataObj isKindOfClass:[NSDictionary class]]) {
                NSDictionary *resumeDict = resumeDataObj;
                yctask.tmpName = [resumeDict valueForKey:@"NSURLSessionResumeInfoTempFileName"];
            }
            //            [[YCResumeData alloc] initWithResumeData:resumeData];
            yctask.resumeData = resumeData;
            yctask.downloadTask = nil;
            [self saveDownloadStatus];
            [self downloadStatusChanged:kDownloadStatusPaused task:yctask];
            
        }else{
            if (yctask.fileSize == 0) {
                [self downloadStatusChanged:kDownloadStatusPaused task:yctask];
            } else {
                [self downloadStatusChanged:kDownloadStatusFailed task:yctask];
            }
        }
    }
    
    //需要下载下一个任务则下载下一个，否则还原noNeedToStartNext标识
    !yctask.noNeedToStartNext ? [self startNextDownloadTask] :  (yctask.noNeedToStartNext = false);
}

@end


