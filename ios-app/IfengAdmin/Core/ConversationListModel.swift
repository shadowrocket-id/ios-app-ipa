import Foundation
import SwiftUI
import Combine

/// 会话列表数据源：真实分页 + SSE 增量合并，筛选走服务端参数。
@MainActor
final class ConversationListModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case open
        case resolved
        case all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .open: return "待处理"
            case .resolved: return "已完成"
            case .all: return "全部"
            }
        }
    }

    @Published private(set) var items: [Conversation] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var errorMessage: String?
    @Published var filter: Filter = .all {
        didSet {
            guard oldValue != filter else { return }
            Task { await reload() }
        }
    }

    private let api: APIClient
    private let inboxId: Int?
    /// 当前登录用户。conversation.read 事件带 user_id，只认自己那条。
    private let userId: Int
    private var page = 1
    private var didLoad = false
    /// SSE 连接状态。只用来调节轮询间隔（3 秒 / 6 秒），**不再**决定是否轮询。
    private var realtimeHealthy: Bool?
    /// 常驻轮询任务。列表页在屏幕上时一直跑，离开时停。
    private var pollTask: Task<Void, Never>?
    /// 防止弱网下刷新请求堆叠。
    private var isRefreshing = false
    /// 聊天页 / 网页后台改动的会话会通过缓存广播过来，这里订阅后直接改本地数组，
    /// 不需要重新请求整个列表。
    private var cacheObserver: AnyCancellable?

    init(session: AppSession, inboxId: Int? = nil) {
        self.api = session.api
        self.inboxId = inboxId
        self.userId = session.profile.id
        cacheObserver = ConversationCache.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                guard let self else { return }
                Task { @MainActor in self.applyCached(update) }
            }
    }

    // MARK: 加载

    /// 首次进入加载；从聊天页返回时强制拉一次真实数据。
    ///
    /// 返回列表这一步尤其重要：离开时列表可能停在旧未读数上，
    /// 而「把未读直接改成 0」是错的（服务端才是唯一依据），所以这里重新取一次。
    func activate() async {
        if didLoad {
            await refresh()
        } else {
            didLoad = true
            await reload()
        }
        // 常驻兜底：SSE 只负责「更快」，列表正确性不能依赖它。
        startPolling()
    }

    /// 视图把 `app.realtimeHealthy` 同步进来，**只用于调节轮询间隔**：
    /// 健康 4 秒、不健康 3 秒。通道恢复时额外补一次，追平断线期间漏掉的角标。
    func setRealtimeHealthy(_ healthy: Bool) async {
        let changed = realtimeHealthy != healthy
        realtimeHealthy = healthy
        guard changed, healthy, didLoad else { return }
        await refresh()
    }

    /// 常驻轮询。未读角标、新会话、预览文字都能在 SSE 不通时自己追上。
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval: TimeInterval = (self?.realtimeHealthy ?? false) ? 4 : 3
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        let requestedFilter = filter
        do {
            let page = try await api.conversations(status: requestedFilter.rawValue, page: 1, inboxId: inboxId)
            guard requestedFilter == filter else { return }
            self.page = 1
            items = page.data.payload
            ConversationCache.store(items)
            hasMore = page.data.payload.count >= AppConfig.pageSize
            errorMessage = nil
        } catch let error as APIError {
            if error.kind == .cancelled { return }
            errorMessage = error.message
        } catch {
            errorMessage = "加载会话失败。"
        }
        isLoading = false
    }

    func refresh() async {
        // 弱网下上一轮可能还没返回，直接跳过，避免请求堆叠。
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // 下拉刷新只取第一页，避免把用户已加载的历史页打乱。
        let requestedFilter = filter
        do {
            let page = try await api.conversations(status: requestedFilter.rawValue, page: 1, inboxId: inboxId)
            guard requestedFilter == filter else { return }
            var merged = page.data.payload
            let ids = Set(merged.map { $0.id })
            for item in items where !ids.contains(item.id) {
                merged.append(item)
            }
            items = merged.sorted { $0.activityTimestamp > $1.activityTimestamp }
            ConversationCache.store(items)
            self.page = max(self.page, 1)
            hasMore = page.data.payload.count >= AppConfig.pageSize
            errorMessage = nil
        } catch let error as APIError {
            if error.kind != .cancelled { errorMessage = error.message }
        } catch {
            errorMessage = "刷新失败。"
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        let nextPage = page + 1
        let requestedFilter = filter
        do {
            let result = try await api.conversations(status: requestedFilter.rawValue, page: nextPage, inboxId: inboxId)
            guard requestedFilter == filter else { return }
            page = nextPage
            let existing = Set(items.map { $0.id })
            let fresh = result.data.payload.filter { !existing.contains($0.id) }
            items.append(contentsOf: fresh)
            ConversationCache.store(fresh)
            hasMore = result.data.payload.count >= AppConfig.pageSize
        } catch let error as APIError {
            if error.kind != .cancelled { errorMessage = error.message }
        } catch {
            errorMessage = "加载更多失败。"
        }
        isLoadingMore = false
    }

    // MARK: 实时事件

    func handle(event: RealtimeEvent) async {
        switch event.kind {
        case .messageCreated:
            guard let conversationId = event.conversationId else { return }
            await refreshConversation(id: conversationId)
        case .conversationUpdated, .conversationStatusChanged:
            guard let conversationId = event.conversationId else { return }
            await refreshConversation(id: conversationId)
        case .conversationRead:
            guard let conversationId = event.conversationId else { return }
            // 未读数是按用户算的：别人的已读事件跟我们无关。
            if let owner = event.userId, owner != userId { return }
            if let unread = event.unreadCount {
                applyUnread(id: conversationId, unread: unread)
            } else {
                await refreshConversation(id: conversationId)
            }
        case .resyncRequired:
            await reload()
        default:
            break
        }
    }

    func refreshConversation(id: Int) async {
        do {
            let conversation = try await api.conversation(id: id)
            if matchesFilter(conversation) {
                upsert(conversation)
            } else {
                items.removeAll { $0.id == id }
            }
        } catch let error as APIError {
            // 404 = 无权限或已删除；直接移除，不弹错。
            if error.kind == .notFound {
                items.removeAll { $0.id == id }
            }
        } catch {
            // 忽略单条刷新失败，等待下一次事件或下拉刷新。
        }
    }

    /// SSE 直接推来了未读数，不用再请求会话详情。
    private func applyUnread(id: Int, unread: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].unreadCount != unread else { return }
        items[index].unreadCount = unread
        ConversationCache.store(items[index])
    }

    /// 缓存广播：聊天页刷新了会话详情 / 清零了未读，列表跟着变。
    private func applyCached(_ update: ConversationCache.ConversationUpdate) {
        let conversation = update.conversation
        guard let index = items.firstIndex(where: { $0.id == conversation.id }) else { return }
        guard items[index] != conversation else { return }

        // 未读数是按用户算的最新值，只有权威来源（markSeen 返回值 / conversation.read
        // 事件）才允许覆盖；普通详情快照可能比它旧，覆盖会让刚清零的角标跳回来。
        guard update.unreadAuthoritative else {
            applyCachedWithoutUnread(conversation)
            return
        }
        if matchesFilter(conversation) {
            items[index] = conversation
            items.sort { lhs, rhs in
                if lhs.activityTimestamp == rhs.activityTimestamp { return lhs.id > rhs.id }
                return lhs.activityTimestamp > rhs.activityTimestamp
            }
        } else {
            items.removeAll { $0.id == conversation.id }
        }
    }

    /// 非权威快照：只同步预览内容 / 状态 / 时间，未读数保留本地的。
    private func applyCachedWithoutUnread(_ conversation: Conversation) {
        guard let index = items.firstIndex(where: { $0.id == conversation.id }) else { return }
        if conversation.activityTimestamp < items[index].activityTimestamp {
            // 更旧的快照连预览都不该覆盖。
            return
        }
        var merged = conversation
        merged.unreadCount = items[index].unreadCount
        if matchesFilter(merged) {
            items[index] = merged
            items.sort { lhs, rhs in
                if lhs.activityTimestamp == rhs.activityTimestamp { return lhs.id > rhs.id }
                return lhs.activityTimestamp > rhs.activityTimestamp
            }
        } else {
            items.removeAll { $0.id == conversation.id }
        }
    }

    private func matchesFilter(_ conversation: Conversation) -> Bool {
        switch filter {
        case .all: return true
        case .open: return conversation.status == "open"
        case .resolved: return conversation.status == "resolved"
        }
    }

    private func upsert(_ conversation: Conversation) {
        ConversationCache.store(conversation)
        if let index = items.firstIndex(where: { $0.id == conversation.id }) {
            items[index] = conversation
        } else {
            items.append(conversation)
        }
        items.sort { lhs, rhs in
            if lhs.activityTimestamp == rhs.activityTimestamp { return lhs.id > rhs.id }
            return lhs.activityTimestamp > rhs.activityTimestamp
        }
    }
}
