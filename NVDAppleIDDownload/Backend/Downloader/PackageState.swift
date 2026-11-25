//
//  PackageState.swift
//  NVDAppleIDDownload
//
//  Created by qaq on 9/15/25.
//

import Foundation

struct PackageState: Codable, Hashable, Equatable {
    enum Status: String, Codable, Equatable, Hashable {
        case pending
        case downloading
        case paused
        case completed
        case failed
    }

    var status: Status = .pending
    var percent: Double = 0 {
        didSet { assert(percent >= 0 && percent <= 1) }
    }

    var error: String? = nil {
        didSet {
            if error != nil {
                status = .failed
            }
        }
    }

    var speed: String = ""

    /// Số byte đã tải + tổng số byte (đợt 4, build 9 — tải nền):
    /// ghi vào trạng thái để mở lại app vẫn hiện đúng tiến độ. Cả hai
    /// đều có giá trị mặc định nên manifest cũ (không có 2 trường này)
    /// vẫn giải mã được (decodeIfPresent).
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
}

extension PackageState {
    mutating func start() {
        status = .pending
        error = nil
    }

    mutating func resetIfNotCompleted() {
        guard [.pending, .downloading].contains(status) else { return }
        status = .paused
    }

    mutating func complete() {
        status = .completed
        percent = 1
        speed = ""
        error = nil
        if totalBytes > 0 {
            downloadedBytes = totalBytes
        }
    }
}
