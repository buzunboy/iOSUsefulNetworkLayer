//
//  NetworkLayer.swift
//  DCA_iOS
//
//  Created by Burak Uzunboy on 25.07.19.
//  Copyright © 2019 Exozet. All rights reserved.
//

import Foundation
import UIKit

/**
 Base Network Layer that capable to cache and manage the operation queue.
 */
public class NetworkLayer: NSObject, URLSessionDataDelegate {
    
    /**
     Network Layer operations completes block with the Response type.
     
     Response will whether return error as `NSError` or the success with the specified type of response object.
     */
    public enum Result<T> where T: ResponseBodyParsable {
        /// Returns response.
        case success(T)
        /// Returns reason of the error.
        case error(NSError)
    }
    
    // MARK: - Properties
    
    /// Singleton instance for the `NetworkLayer`.
    public static let shared = NetworkLayer()
    
    /// Operations marked as main are being handled by this queue.
    var mainQueue: OperationQueue {
        didSet {
            self.mainQueue.maxConcurrentOperationCount = 1
            self.mainQueue.qualityOfService = .userInitiated
            self.mainQueue.name = "\(Bundle.main.bundleIdentifier!).operationQueue"
        }}
    
    /// Operations not marked as main queue are being handled by this queue.
    var backgroundQueue: OperationQueue {
        didSet {
            self.backgroundQueue.maxConcurrentOperationCount = OperationQueue.defaultMaxConcurrentOperationCount
            self.backgroundQueue.qualityOfService = .default
            self.backgroundQueue.name = "\(Bundle.main.bundleIdentifier!).backgroundQueue"
        }}
    
    /// Block that holds log message, level and caller function.
    public typealias LogListenerBlock = (_ message: String, _ func: String, _ level: LogType)->()
    /// Holds listener for the logs created by the `NetworkLayer`.
    private var logListener: LogListenerBlock?
    
    /// Holds cache of the `NetworkLayer`.
    var cache: Cache? {
        get {
            return NetworkLayer.Cache(memoryCapacity: 0,
                                      diskCapacity: 150 * 1024 * 1024,
                                      diskPath: nil)
        }
    }
    
    /// `URLSession` manager for the `NetworkLayer`.
    var urlSession: URLSession!
    
    /// Private initializer
    private override init() {
        self.mainQueue = OperationQueue()
        self.backgroundQueue = OperationQueue()
        super.init()
        
        let conf = URLSessionConfiguration.default
        conf.requestCachePolicy = .reloadIgnoringCacheData
        conf.urlCache = self.cache
        
        self.urlSession = URLSession.init(configuration: conf,
                                          delegate: self,
                                          delegateQueue: nil)
    }
    
    /// Removes observers.
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: Public Methods
    
    /**
     Executes configured API.
     - parameter request: All information/configurations needed to execute API
     - parameter completion: Completion block which will be called when operation is completed
     - parameter error: Returns reason of the error if operation fails. `nil` otherwise
     - parameter response: Returns response with the specified type of response
     */
    public func execute<T>(_ request: APIConfiguration<T>, completion: @escaping (Result<T>)->()) where T:ResponseBodyParsable {
        DispatchQueue.global().async { [unowned self] in
            guard let urlRequest = request.request else {
                let err = NSError(domain: "", code: 500, description: "Cannot create URL Request with specified configurations")
                self.sendLog(message: err.localizedDescription, logType: .error(code: 900, name: err.localizedDescription))
                DispatchQueue.main.async {
                    completion(.error(err))
                }
                return
            }
            
            // create task and operation
            let id = Int(Date().timeIntervalSince1970 * 1000)
            var operation: APIOperation!
            var task: URLSessionDataTask!
            
            task = self.urlSession.dataTask(with: urlRequest) { [unowned self](data, response, error) in
                guard operation != nil else { return }
                
                self.sendLog(message: "Data Task for Operation ID: \(operation.identifier) is completed - URL: \(urlRequest.url?.absoluteString ?? "nil")")
                operation.isFinished = true
                var dataResult = data
                var loadedResponse = response
                
                if let error = error {
                    if let oldCacheObject = self.cache?.cachedResponseWithForce(for: urlRequest) {
                        dataResult = oldCacheObject.data
                        loadedResponse = oldCacheObject.response
                    } else {
                        self.sendLog(message: "Operation:\(operation.identifier) failed with error: \(error.localizedDescription)", logType: .error(code: (error as NSError).code, name: error.localizedDescription))
                        DispatchQueue.main.async {
                            completion(.error(error as NSError))
                        }
                        return
                    }
                }
                
                self.cache?.changeCacheExpiry(for: task, to: request.cachingTime.expirationDate ?? Date())
                
                guard let data = dataResult, let loadResponse = loadedResponse else {
                    let err = NSError(domain: "", code: 500, description: "Data is empty - Operation: \(operation.identifier)")
                    DispatchQueue.main.async {
                        completion(.error(err))
                    }
                    return
                }
                
                self.proceedResponse(response: loadResponse, data: data, operationId: operation.identifier, request: request, completion: completion)
            }
            
            self.cache?.getCachedResponse(for: task, completionHandler: { (response) in
                if let response = response {
                    // found in the cache, proceed
                    self.sendLog(message: "Operation with ID: \(id) is gathered from the cache - Caching ends: \(response.userInfo?["cachingEndsAt"] ?? "Nil")")
                    self.proceedResponse(response: response.response,
                                         data: response.data,
                                         operationId: id,
                                         request: request,
                                         completion: completion)
                    task.cancel()
                } else {
                    operation = request.operation(with: task, id: id)
                    self.sendLog(message: "Operation with ID: \(operation.identifier) is created - URL: \(request.requestURL)")
                    operation.layerDelegate = self
                    request.isMainOperation ? self.mainQueue.addOperation(operation) : self.backgroundQueue.addOperation(operation)
                    
                    operation.completionBlock = { [unowned self] in
                        self.sendLog(message: "Operation with ID: \(operation.identifier) is completed")
                    }
                    
                    self.sendLog(message: "Operation with ID: \(operation.identifier) is added to queue - isMainQueue: \(request.isMainOperation)")
                }
            })
        }
    }
    
    /// Proceeds the response and completes.
    private func proceedResponse<T>(response: URLResponse, data: Data,
                                    operationId: Int,
                                    request: APIConfiguration<T>,
                                    completion: @escaping (Result<T>)->()) where T: ResponseBodyParsable {
        
        if let dataObject = request.responseBodyObject.init(data) {
            self.sendLog(message: "Data Object created from Operation: \(operationId) - Object: \(dataObject.typeName)")
            if request.autoCache, let cacheTiming = dataObject.cachingEndsAt() {
                self.cache?.changeCacheExpiry(for: request.request!, to: cacheTiming)
            }
            DispatchQueue.main.async {
                completion(.success(dataObject))
            }
            return
        }
        
        do {
            let json = try JSONSerialization.jsonObject(with: data, options: .allowFragments)
            if let responseObject = request.responseBodyObject.init(json) {
                self.sendLog(message: "Response Object Created from JSON Data with Operation: \(operationId) - Object: \(responseObject.typeName)")
                if request.autoCache, let cacheTiming = responseObject.cachingEndsAt() {
                    self.cache?.changeCacheExpiry(for: request.request!, to: cacheTiming)
                }
                DispatchQueue.main.async {
                    completion(.success(responseObject))
                }
            } else {
                DispatchQueue.main.async {
                    let err = NSError(domain: "", code: 500, description: "Cannot create response body - Operation: \(operationId)")
                    completion(.error(err))
                }
            }
        } catch {
            self.sendLog(message: "Couldn't create JSON Data from Operation: \(operationId) - Error: \(error.localizedDescription)",
                logType: .error(code: 900, name: error.localizedDescription))
            DispatchQueue.main.async {
                let err = NSError(domain: "", code: 500, description: error.localizedDescription)
                completion(.error(err))
            }
        }
    }
    
    /**
     Sets listener for the log messages coming from the `NetworkLayer`.
     - parameter listener: Listener Block
     - parameter message: Message of the log
     - parameter func: Function who creates the log
     */
    public func setLogListener(_ listener: @escaping LogListenerBlock) {
        self.logListener = listener
    }
    
    // MARK: Private Methods
    
    /**
     Sends logs to listener. Shouldn't be called outside of the `NetworkLayer`.
     - parameter message: Log message
     - parameter function: Caller of the log
     */
    internal func sendLog(message: String, function: String = #function, logType: LogType = .info) {
        self.logListener?(message, function, logType)
    }
    
    /// Two log type is currently possible. Info or error with the code and name.
    public enum LogType {
        /// Default log type for the network layer
        case info
        /// Logs with the code and name of the error
        case error(code: Int, name: String)
    }
    
}