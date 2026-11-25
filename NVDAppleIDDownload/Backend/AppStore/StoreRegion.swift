//  StoreRegion.swift
//  NVDAppleIDDownload
//
//  Vùng App Store để tìm kiếm, độc lập với vùng của tài khoản (đợt 2,
//  build 7 — ý tưởng iPadn mục 4, viết lại sạch).
//
//  Danh sách mã vùng là dữ liệu sự thật (ISO 3166-1 alpha-2), không phải
//  code có bản quyền: 175 cửa hàng App Store Apple đang vận hành (đã kiểm
//  chứng bằng dữ liệu tra cứu công khai của Apple ngày 12/11/2026 — đúng
//  175 mã trả về kết quả, khớp con số Apple công bố) + 2 vùng trong danh
//  sách vùng của Apple nhưng chưa xác minh được có cửa hàng riêng không:
//  AD (Andorra) và MC (Monaco). iPadn ghi 177 vùng; 2 mã cộng thêm này là
//  phần chênh lệch chưa xác minh được — tìm ở vùng đó mà Apple không trả
//  kết quả thì chỉ là không có app, không lỗi gì. Cần kiểm chứng trên máy
//  thật bằng cách tìm thử ở vùng AD / MC.
//
//  Vùng tìm kiếm CHỈ dùng cho tìm app (Searcher.search), tra cứu catalog
//  (Lookup / catalogVersion) và màn chi tiết app. Vùng của tài khoản (để
//  mua license / tải IPA) vẫn lấy theo từng tài khoản như trước — Apple
//  chỉ cho mua theo đúng cửa hàng của tài khoản, không đổi được.
//

import Foundation

/// Một vùng App Store: mã ISO-2 + tên tiếng Việt + tên tiếng Anh (để tìm).
struct StoreRegion: Identifiable, Hashable, Codable {
    let code: String
    let vietnameseName: String
    let englishName: String

    var id: String { code }
}

enum StoreRegionCatalog {
    /// Toàn bộ 177 vùng, xếp theo tên tiếng Anh (thứ tự như danh sách của
    /// Apple) để dễ đối chiếu. 175 vùng đầu là các cửa hàng đã kiểm chứng;
    /// 2 vùng cuối (AD, MC) là vùng cộng thêm chưa xác minh cửa hàng.
    static let all: [StoreRegion] = [
        StoreRegion(code: "AF", vietnameseName: "Áp-ga-ni-xtan", englishName: "Afghanistan"),
        StoreRegion(code: "AL", vietnameseName: "An-ba-ni", englishName: "Albania"),
        StoreRegion(code: "DZ", vietnameseName: "An-giê-ri", englishName: "Algeria"),
        StoreRegion(code: "AO", vietnameseName: "Ăng-gô-la", englishName: "Angola"),
        StoreRegion(code: "AI", vietnameseName: "Ăng-ghi-la", englishName: "Anguilla"),
        StoreRegion(code: "AG", vietnameseName: "An-ti-goa và Bác-bu-đa", englishName: "Antigua & Barbuda"),
        StoreRegion(code: "AR", vietnameseName: "Ác-hen-ti-na", englishName: "Argentina"),
        StoreRegion(code: "AM", vietnameseName: "Ác-mê-ni-a", englishName: "Armenia"),
        StoreRegion(code: "AU", vietnameseName: "Úc", englishName: "Australia"),
        StoreRegion(code: "AT", vietnameseName: "Áo", englishName: "Austria"),
        StoreRegion(code: "AZ", vietnameseName: "A-déc-bai-gian", englishName: "Azerbaijan"),
        StoreRegion(code: "BS", vietnameseName: "Ba-ha-ma", englishName: "Bahamas"),
        StoreRegion(code: "BH", vietnameseName: "Ba-ranh", englishName: "Bahrain"),
        StoreRegion(code: "BB", vietnameseName: "Bác-ba-đốt", englishName: "Barbados"),
        StoreRegion(code: "BY", vietnameseName: "Bê-la-rút", englishName: "Belarus"),
        StoreRegion(code: "BE", vietnameseName: "Bỉ", englishName: "Belgium"),
        StoreRegion(code: "BZ", vietnameseName: "Bê-li-xê", englishName: "Belize"),
        StoreRegion(code: "BJ", vietnameseName: "Bê-nanh", englishName: "Benin"),
        StoreRegion(code: "BM", vietnameseName: "Béc-mu-đa", englishName: "Bermuda"),
        StoreRegion(code: "BT", vietnameseName: "Bu-tan", englishName: "Bhutan"),
        StoreRegion(code: "BO", vietnameseName: "Bô-li-vi-a", englishName: "Bolivia"),
        StoreRegion(code: "BA", vietnameseName: "Bốt-ni-a và Héc-xê-gô-vi-na", englishName: "Bosnia & Herzegovina"),
        StoreRegion(code: "BW", vietnameseName: "Bốt-xoa-na", englishName: "Botswana"),
        StoreRegion(code: "BR", vietnameseName: "Bra-xin", englishName: "Brazil"),
        StoreRegion(code: "VG", vietnameseName: "Quần đảo Virgin thuộc Anh", englishName: "British Virgin Islands"),
        StoreRegion(code: "BN", vietnameseName: "Bru-nây", englishName: "Brunei"),
        StoreRegion(code: "BG", vietnameseName: "Bun-ga-ri", englishName: "Bulgaria"),
        StoreRegion(code: "BF", vietnameseName: "Buốc-ki-na Pha-xô", englishName: "Burkina Faso"),
        StoreRegion(code: "KH", vietnameseName: "Cam-pu-chia", englishName: "Cambodia"),
        StoreRegion(code: "CM", vietnameseName: "Ca-mơ-run", englishName: "Cameroon"),
        StoreRegion(code: "CA", vietnameseName: "Ca-na-đa", englishName: "Canada"),
        StoreRegion(code: "CV", vietnameseName: "Cáp Ve", englishName: "Cape Verde"),
        StoreRegion(code: "KY", vietnameseName: "Quần đảo Cay-man", englishName: "Cayman Islands"),
        StoreRegion(code: "TD", vietnameseName: "Sát", englishName: "Chad"),
        StoreRegion(code: "CL", vietnameseName: "Chi-lê", englishName: "Chile"),
        StoreRegion(code: "CN", vietnameseName: "Trung Quốc", englishName: "China mainland"),
        StoreRegion(code: "CO", vietnameseName: "Cô-lôm-bi-a", englishName: "Colombia"),
        StoreRegion(code: "CG", vietnameseName: "Công-gô (Bra-xa-vin)", englishName: "Congo - Brazzaville"),
        StoreRegion(code: "CD", vietnameseName: "Công-gô (Kin-sa-sa)", englishName: "Congo - Kinshasa"),
        StoreRegion(code: "CR", vietnameseName: "Cốt-xta Ri-ca", englishName: "Costa Rica"),
        StoreRegion(code: "HR", vietnameseName: "Crô-a-ti-a", englishName: "Croatia"),
        StoreRegion(code: "CY", vietnameseName: "Síp", englishName: "Cyprus"),
        StoreRegion(code: "CZ", vietnameseName: "Séc", englishName: "Czechia"),
        StoreRegion(code: "CI", vietnameseName: "Bờ Biển Ngà", englishName: "Côte d'Ivoire"),
        StoreRegion(code: "DK", vietnameseName: "Đan Mạch", englishName: "Denmark"),
        StoreRegion(code: "DM", vietnameseName: "Đô-mi-ni-ca", englishName: "Dominica"),
        StoreRegion(code: "DO", vietnameseName: "Cộng hòa Đô-mi-ni-ca", englishName: "Dominican Republic"),
        StoreRegion(code: "EC", vietnameseName: "Ê-cu-a-đo", englishName: "Ecuador"),
        StoreRegion(code: "EG", vietnameseName: "Ai Cập", englishName: "Egypt"),
        StoreRegion(code: "SV", vietnameseName: "En Xan-va-đo", englishName: "El Salvador"),
        StoreRegion(code: "EE", vietnameseName: "Ét-xtô-ni-a", englishName: "Estonia"),
        StoreRegion(code: "SZ", vietnameseName: "E-xoa-ti-ni", englishName: "Eswatini"),
        StoreRegion(code: "FJ", vietnameseName: "Phi-gi", englishName: "Fiji"),
        StoreRegion(code: "FI", vietnameseName: "Phần Lan", englishName: "Finland"),
        StoreRegion(code: "FR", vietnameseName: "Pháp", englishName: "France"),
        StoreRegion(code: "GA", vietnameseName: "Ga-bông", englishName: "Gabon"),
        StoreRegion(code: "GM", vietnameseName: "Găm-bi-a", englishName: "Gambia"),
        StoreRegion(code: "GE", vietnameseName: "Gru-di-a", englishName: "Georgia"),
        StoreRegion(code: "DE", vietnameseName: "Đức", englishName: "Germany"),
        StoreRegion(code: "GH", vietnameseName: "Ga-na", englishName: "Ghana"),
        StoreRegion(code: "GR", vietnameseName: "Hy Lạp", englishName: "Greece"),
        StoreRegion(code: "GD", vietnameseName: "Grê-na-đa", englishName: "Grenada"),
        StoreRegion(code: "GT", vietnameseName: "Gua-tê-ma-la", englishName: "Guatemala"),
        StoreRegion(code: "GW", vietnameseName: "Ghi-nê Bít-xao", englishName: "Guinea-Bissau"),
        StoreRegion(code: "GY", vietnameseName: "Guy-a-na", englishName: "Guyana"),
        StoreRegion(code: "HN", vietnameseName: "Hon-đu-rát", englishName: "Honduras"),
        StoreRegion(code: "HK", vietnameseName: "Hồng Kông", englishName: "Hong Kong"),
        StoreRegion(code: "HU", vietnameseName: "Hung-ga-ri", englishName: "Hungary"),
        StoreRegion(code: "IS", vietnameseName: "Ai-xơ-len", englishName: "Iceland"),
        StoreRegion(code: "IN", vietnameseName: "Ấn Độ", englishName: "India"),
        StoreRegion(code: "ID", vietnameseName: "In-đô-nê-xi-a", englishName: "Indonesia"),
        StoreRegion(code: "IQ", vietnameseName: "I-rắc", englishName: "Iraq"),
        StoreRegion(code: "IE", vietnameseName: "Ai-len", englishName: "Ireland"),
        StoreRegion(code: "IL", vietnameseName: "I-xra-en", englishName: "Israel"),
        StoreRegion(code: "IT", vietnameseName: "Ý", englishName: "Italy"),
        StoreRegion(code: "JM", vietnameseName: "Gia-mai-ca", englishName: "Jamaica"),
        StoreRegion(code: "JP", vietnameseName: "Nhật Bản", englishName: "Japan"),
        StoreRegion(code: "JO", vietnameseName: "Gioóc-đa-ni", englishName: "Jordan"),
        StoreRegion(code: "KZ", vietnameseName: "Ca-dắc-xtan", englishName: "Kazakhstan"),
        StoreRegion(code: "KE", vietnameseName: "Kê-ni-a", englishName: "Kenya"),
        StoreRegion(code: "XK", vietnameseName: "Cô-xô-vô", englishName: "Kosovo"),
        StoreRegion(code: "KW", vietnameseName: "Cô-oét", englishName: "Kuwait"),
        StoreRegion(code: "KG", vietnameseName: "Cư-rơ-gư-xtan", englishName: "Kyrgyzstan"),
        StoreRegion(code: "LA", vietnameseName: "Lào", englishName: "Laos"),
        StoreRegion(code: "LV", vietnameseName: "Lát-vi-a", englishName: "Latvia"),
        StoreRegion(code: "LB", vietnameseName: "Li-băng", englishName: "Lebanon"),
        StoreRegion(code: "LR", vietnameseName: "Li-bê-ri-a", englishName: "Liberia"),
        StoreRegion(code: "LY", vietnameseName: "Li-bi", englishName: "Libya"),
        StoreRegion(code: "LT", vietnameseName: "Lít-va", englishName: "Lithuania"),
        StoreRegion(code: "LU", vietnameseName: "Lúc-xăm-bua", englishName: "Luxembourg"),
        StoreRegion(code: "MO", vietnameseName: "Ma-cao", englishName: "Macao"),
        StoreRegion(code: "MG", vietnameseName: "Ma-đa-gát-xca", englishName: "Madagascar"),
        StoreRegion(code: "MW", vietnameseName: "Ma-la-uy", englishName: "Malawi"),
        StoreRegion(code: "MY", vietnameseName: "Ma-lai-xi-a", englishName: "Malaysia"),
        StoreRegion(code: "MV", vietnameseName: "Man-đi-vơ", englishName: "Maldives"),
        StoreRegion(code: "ML", vietnameseName: "Ma-li", englishName: "Mali"),
        StoreRegion(code: "MT", vietnameseName: "Man-ta", englishName: "Malta"),
        StoreRegion(code: "MR", vietnameseName: "Mô-ri-ta-ni", englishName: "Mauritania"),
        StoreRegion(code: "MU", vietnameseName: "Mô-ri-xơ", englishName: "Mauritius"),
        StoreRegion(code: "MX", vietnameseName: "Mê-hi-cô", englishName: "Mexico"),
        StoreRegion(code: "FM", vietnameseName: "Mi-crô-nê-xi-a", englishName: "Micronesia"),
        StoreRegion(code: "MD", vietnameseName: "Môn-đô-va", englishName: "Moldova"),
        StoreRegion(code: "MN", vietnameseName: "Mông Cổ", englishName: "Mongolia"),
        StoreRegion(code: "ME", vietnameseName: "Môn-tê-nê-grô", englishName: "Montenegro"),
        StoreRegion(code: "MS", vietnameseName: "Montserrat", englishName: "Montserrat"),
        StoreRegion(code: "MA", vietnameseName: "Ma-rốc", englishName: "Morocco"),
        StoreRegion(code: "MZ", vietnameseName: "Mô-dăm-bích", englishName: "Mozambique"),
        StoreRegion(code: "MM", vietnameseName: "Mi-an-ma", englishName: "Myanmar (Burma)"),
        StoreRegion(code: "NA", vietnameseName: "Na-mi-bi-a", englishName: "Namibia"),
        StoreRegion(code: "NR", vietnameseName: "Na-u-ru", englishName: "Nauru"),
        StoreRegion(code: "NP", vietnameseName: "Nê-pan", englishName: "Nepal"),
        StoreRegion(code: "NL", vietnameseName: "Hà Lan", englishName: "Netherlands"),
        StoreRegion(code: "NZ", vietnameseName: "Niu Di-lân", englishName: "New Zealand"),
        StoreRegion(code: "NI", vietnameseName: "Ni-ca-ra-goa", englishName: "Nicaragua"),
        StoreRegion(code: "NE", vietnameseName: "Ni-giê", englishName: "Niger"),
        StoreRegion(code: "NG", vietnameseName: "Ni-giê-ri-a", englishName: "Nigeria"),
        StoreRegion(code: "MK", vietnameseName: "Bắc Ma-xê-đô-ni-a", englishName: "North Macedonia"),
        StoreRegion(code: "NO", vietnameseName: "Na Uy", englishName: "Norway"),
        StoreRegion(code: "OM", vietnameseName: "Ô-man", englishName: "Oman"),
        StoreRegion(code: "PK", vietnameseName: "Pa-ki-xtan", englishName: "Pakistan"),
        StoreRegion(code: "PW", vietnameseName: "Pa-lau", englishName: "Palau"),
        StoreRegion(code: "PA", vietnameseName: "Pa-na-ma", englishName: "Panama"),
        StoreRegion(code: "PG", vietnameseName: "Pa-pua Niu Ghi-nê", englishName: "Papua New Guinea"),
        StoreRegion(code: "PY", vietnameseName: "Pa-ra-goay", englishName: "Paraguay"),
        StoreRegion(code: "PE", vietnameseName: "Pê-ru", englishName: "Peru"),
        StoreRegion(code: "PH", vietnameseName: "Phi-líp-pin", englishName: "Philippines"),
        StoreRegion(code: "PL", vietnameseName: "Ba Lan", englishName: "Poland"),
        StoreRegion(code: "PT", vietnameseName: "Bồ Đào Nha", englishName: "Portugal"),
        StoreRegion(code: "QA", vietnameseName: "Ca-ta", englishName: "Qatar"),
        StoreRegion(code: "RO", vietnameseName: "Ru-ma-ni", englishName: "Romania"),
        StoreRegion(code: "RU", vietnameseName: "Nga", englishName: "Russia"),
        StoreRegion(code: "RW", vietnameseName: "Ru-an-đa", englishName: "Rwanda"),
        StoreRegion(code: "SA", vietnameseName: "Ả Rập Xê-út", englishName: "Saudi Arabia"),
        StoreRegion(code: "SN", vietnameseName: "Xê-nê-gan", englishName: "Senegal"),
        StoreRegion(code: "RS", vietnameseName: "Xéc-bi-a", englishName: "Serbia"),
        StoreRegion(code: "SC", vietnameseName: "Xây-sen", englishName: "Seychelles"),
        StoreRegion(code: "SL", vietnameseName: "Xi-ê-ra Lê-ôn", englishName: "Sierra Leone"),
        StoreRegion(code: "SG", vietnameseName: "Xing-ga-po", englishName: "Singapore"),
        StoreRegion(code: "SK", vietnameseName: "Xlô-va-ki-a", englishName: "Slovakia"),
        StoreRegion(code: "SI", vietnameseName: "Xlô-ven-ni-a", englishName: "Slovenia"),
        StoreRegion(code: "SB", vietnameseName: "Quần đảo Xô-lô-môn", englishName: "Solomon Islands"),
        StoreRegion(code: "ZA", vietnameseName: "Nam Phi", englishName: "South Africa"),
        StoreRegion(code: "KR", vietnameseName: "Hàn Quốc", englishName: "South Korea"),
        StoreRegion(code: "ES", vietnameseName: "Tây Ban Nha", englishName: "Spain"),
        StoreRegion(code: "LK", vietnameseName: "Sri Lan-ka", englishName: "Sri Lanka"),
        StoreRegion(code: "KN", vietnameseName: "Xanh Kít và Nê-vít", englishName: "St. Kitts & Nevis"),
        StoreRegion(code: "LC", vietnameseName: "Xanh Lu-xi-a", englishName: "St. Lucia"),
        StoreRegion(code: "VC", vietnameseName: "Xanh Vin-xen và Grê-na-din", englishName: "St. Vincent & Grenadines"),
        StoreRegion(code: "SR", vietnameseName: "Xu-ri-nam", englishName: "Suriname"),
        StoreRegion(code: "SE", vietnameseName: "Thụy Điển", englishName: "Sweden"),
        StoreRegion(code: "CH", vietnameseName: "Thụy Sĩ", englishName: "Switzerland"),
        StoreRegion(code: "ST", vietnameseName: "Xao Tô-mê và Prin-xi-pê", englishName: "São Tomé & Príncipe"),
        StoreRegion(code: "TW", vietnameseName: "Đài Loan", englishName: "Taiwan"),
        StoreRegion(code: "TJ", vietnameseName: "Tát-gi-ki-xtan", englishName: "Tajikistan"),
        StoreRegion(code: "TZ", vietnameseName: "Tan-da-ni-a", englishName: "Tanzania"),
        StoreRegion(code: "TH", vietnameseName: "Thái Lan", englishName: "Thailand"),
        StoreRegion(code: "TO", vietnameseName: "Tông-ga", englishName: "Tonga"),
        StoreRegion(code: "TT", vietnameseName: "Tri-ni-đát và Tô-ba-gô", englishName: "Trinidad & Tobago"),
        StoreRegion(code: "TN", vietnameseName: "Tuy-ni-di", englishName: "Tunisia"),
        StoreRegion(code: "TM", vietnameseName: "Tuốc-mê-ni-xtan", englishName: "Turkmenistan"),
        StoreRegion(code: "TC", vietnameseName: "Quần đảo Tớc và Cai-cốt", englishName: "Turks & Caicos Islands"),
        StoreRegion(code: "TR", vietnameseName: "Thổ Nhĩ Kỳ", englishName: "Türkiye"),
        StoreRegion(code: "UG", vietnameseName: "U-gan-đa", englishName: "Uganda"),
        StoreRegion(code: "UA", vietnameseName: "U-crai-na", englishName: "Ukraine"),
        StoreRegion(code: "AE", vietnameseName: "Các Tiểu vương quốc Ả Rập Thống nhất", englishName: "United Arab Emirates"),
        StoreRegion(code: "GB", vietnameseName: "Vương quốc Anh", englishName: "United Kingdom"),
        StoreRegion(code: "US", vietnameseName: "Hoa Kỳ", englishName: "United States"),
        StoreRegion(code: "UY", vietnameseName: "U-ru-goay", englishName: "Uruguay"),
        StoreRegion(code: "UZ", vietnameseName: "U-dơ-bê-ki-xtan", englishName: "Uzbekistan"),
        StoreRegion(code: "VU", vietnameseName: "Va-nu-a-tu", englishName: "Vanuatu"),
        StoreRegion(code: "VE", vietnameseName: "Vê-nê-xu-ê-la", englishName: "Venezuela"),
        StoreRegion(code: "VN", vietnameseName: "Việt Nam", englishName: "Vietnam"),
        StoreRegion(code: "YE", vietnameseName: "Y-ê-men", englishName: "Yemen"),
        StoreRegion(code: "ZM", vietnameseName: "Dăm-bi-a", englishName: "Zambia"),
        StoreRegion(code: "ZW", vietnameseName: "Dim-ba-bu-ê", englishName: "Zimbabwe"),
        // 2 vùng cộng thêm, chưa xác minh có cửa hàng riêng không (xem ghi
        // chú đầu file). Để cuối danh sách để dễ soát lại.
        StoreRegion(code: "AD", vietnameseName: "An-đô-ra", englishName: "Andorra"),
        StoreRegion(code: "MC", vietnameseName: "Mô-na-cô", englishName: "Monaco"),
    ]

    /// Vùng ưa thích mặc định khi chưa chọn gì: vùng của anh Dũng (VN) +
    /// các cửa hàng lớn hay tìm.
    static let defaultFavorites = ["VN", "US", "GB", "JP", "KR", "CN", "SG", "HK", "TW", "IN"]

    /// Mã vùng mặc định khi chưa chọn vùng tìm kiếm lần nào.
    static let defaultSearchRegion = "US"

    static func region(for code: String) -> StoreRegion? {
        all.first { $0.code == code.uppercased() }
    }

    /// Tên tiếng Việt của vùng, vd "Việt Nam". Không có trong bảng thì trả
    /// lại chính mã vùng.
    static func displayName(for code: String) -> String {
        region(for: code)?.vietnameseName ?? code
    }

    /// Dòng hiển thị trong picker: "VN — Việt Nam".
    static func pickerLabel(for code: String) -> String {
        "\(code) — \(displayName(for: code))"
    }

    /// Vùng có khớp với từ tìm kiếm không (tìm theo tên tiếng Việt, tên
    /// tiếng Anh hoặc mã ISO-2, không phân biệt hoa thường / dấu).
    static func matches(_ region: StoreRegion, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard !needle.isEmpty else { return true }
        let haystacks = [region.code, region.vietnameseName, region.englishName]
            .map { $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }
        return haystacks.contains { $0.contains(needle) }
    }
}
