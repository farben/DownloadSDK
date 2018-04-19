//
//  DownloadSession.h
//  DownloadManager
//
//  Created by liubo on 2018/4/18.
//  Copyright © 2018年 Person. All rights reserved.
//  Github: https://github.com/gitliubo/DownloadSDK.git
//

#import <UIKit/UIKit.h>

#import "DownloadTask.h"

/**当前下载session中所有的任务下载完成的通知。 不包括失败、暂停的任务*/
static NSString * const kDownloadAllTaskFinishedNoti = @"kAllDownloadTaskFinishedNoti";

/**
 * 在swift中找不到头文件中的方法，在这里定义协议
 * 经过测试，找不到方法的，一般是类方法和类名类似的类方法
 */
@protocol DownloadSession
+ (instancetype)downloadSession;
@end

typedef void (^CompletedHandler)(void);
@class DownloadSession;

@interface DownloadSession : NSObject<DownloadSession>

/**
 获取下载session单例
 */
+ (instancetype)downloadSession;


/**
 YCDownloadSession版本号，主要用于大版本更新，兼容旧逻辑
 */
@property (nonatomic, readonly) NSString *downloadVersion;

/**
 设置下载任务的个数，最多支持3个下载任务同时进行。
 NSURLSession最多支持5个任务同时进行
 但是5个任务，在某些情况下，部分任务会出现等待的状态，所有设置最多支持3个
 */
@property (nonatomic, assign) NSInteger maxTaskCount;

/**
 开始一个后台下载任务
 
 @param downloadURLString 下载url
 @param fileId 下载文件的标识。可以为空。要想同- downloadURL文件重复下载，可以让fileId不同
 @param delegate 代理
 @return 创建或者存在的下载任务
 */
- (DownloadTask *)startDownloadWithUrl:(NSString *)downloadURLString fileId:(NSString *)fileId delegate:(id<DownloadTaskDelegate>)delegate;

/**
 暂停一个后台下载任务
 
 @param task 下载task
 */
- (void)pauseDownloadWithTask:(DownloadTask *)task;

/**
 继续开始一个后台下载任务
 
 @param task 下载task
 */
- (void)resumeDownloadWithTask:(DownloadTask *)task;

/**
 删除一个后台下载任务，同时会删除当前任务下载的缓存数据
 
 @param task 下载task
 */
- (void)stopDownloadWithTask:(DownloadTask *)task;

/**
 暂停一个后台下载任务
 
 @param taskId 下载task的标识
 */
- (void)pauseDownloadWithTaskId:(NSString *)taskId;

/**
 继续开始一个后台下载任务
 
 @param taskId 下载task的标识
 */
- (void)resumeDownloadWithTaskId:(NSString *)taskId;


/**
 删除一个后台下载任务，同时会删除当前任务下载的缓存数据
 
 @param taskId 下载task的标识
 */
- (void)stopDownloadWithTaskId:(NSString *)taskId;


/**
 暂停所有的下载
 */
- (void)pauseAllDownloadTask;


/**
 继续所有的下载
 */
- (void)resumeAllDownloadTask;


/**
 清空所有下载的文件
 */
- (void)removeAllCache;


/**
 根据taskid取task
 
 @param taskId taskid
 @return task
 */
- (DownloadTask *)taskForTaskId:(NSString *)taskId;

/**
 是否允许蜂窝煤网络下载，以及网络状态变为蜂窝煤是否允许下载，必须把所有的downloadTask全部暂停，然后重新创建。否则，原先创建的
 下载task依旧在网络切换为蜂窝煤网络时会继续下载
 
 @param isAllow 是否允许蜂窝煤网络下载
 */
- (void)allowsCellularAccess:(BOOL)isAllow;


/**
 获取当前是否允许蜂窝煤访问状态
 */
- (BOOL)isAllowsCellularAccess;


/**
 后台某一下载任务完成时，第一次在AppDelegate中的 -(void)application:(UIApplication *)application handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)(void))completionHandler
 回调方法中调用该方法。多个task，一个session，只调用一次AppDelegate的回调方法。
 completionHandler 回调执行后，app被系统唤醒的状态会变为休眠状态。
 
 @param handler 后台任务结束后的调用的处理方法
 @param identifier background session 的标识
 */
-(void)addCompletionHandler:(CompletedHandler)handler identifier:(NSString *)identifier;


/**
 保存下载数据
 */
- (void)saveDownloadStatus;

@end

