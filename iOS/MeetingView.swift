import SwiftUI

struct MeetingView: View {
    @EnvironmentObject private var model: AppModel
    let recordID: String
    private var record: LedgerItem? { model.records.first { $0.id == recordID } }

    var body: some View {
        Group {
            if let record {
                MeetingReadingScreen(record: record)
                    .id(record.id + (record.ownerKey ?? record.orgId))
            } else {
                ContentUnavailableView("记录不可用", systemImage: "person.crop.circle",
                    description: Text("请确认当前登录的是这条记录所属的账号。"))
            }
        }
        .navigationTitle("录音详情")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: recordID) {
            if record?.transcriptId != nil { await model.refreshRecord(recordID) }
        }
    }
}
