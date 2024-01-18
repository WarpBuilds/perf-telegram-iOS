import Foundation
import Postbox
import TelegramCore
import TemporaryCachedPeerDataManager
import Emoji
import AccountContext
import TelegramPresentationData
import ChatHistoryEntry
import ChatMessageItemCommon

func chatHistoryEntriesForView(
    location: ChatLocation,
    view: MessageHistoryView,
    includeUnreadEntry: Bool,
    includeEmptyEntry: Bool,
    includeChatInfoEntry: Bool,
    includeSearchEntry: Bool,
    reverse: Bool,
    groupMessages: Bool,
    reverseGroupedMessages: Bool,
    selectedMessages: Set<MessageId>?,
    presentationData: ChatPresentationData,
    historyAppearsCleared: Bool,
    skipViewOnceMedia: Bool,
    pendingUnpinnedAllMessages: Bool,
    pendingRemovedMessages: Set<MessageId>,
    associatedData: ChatMessageItemAssociatedData,
    updatingMedia: [MessageId: ChatUpdatingMessageMedia],
    customChannelDiscussionReadState: MessageId?,
    customThreadOutgoingReadState: MessageId?,
    cachedData: CachedPeerData?,
    adMessage: Message?,
    dynamicAdMessages: [Message]
) -> [ChatHistoryEntry] {
    if historyAppearsCleared {
        return []
    }
    var entries: [ChatHistoryEntry] = []
    var adminRanks: [PeerId: CachedChannelAdminRank] = [:]
    var stickersEnabled = true
    var channelPeer: Peer?
    if let peerId = location.peerId, peerId.namespace == Namespaces.Peer.CloudChannel {
        for additionalEntry in view.additionalData {
            if case let .cacheEntry(id, data) = additionalEntry {
                if id == cachedChannelAdminRanksEntryId(peerId: peerId), let data = data?.get(CachedChannelAdminRanks.self) {
                    adminRanks = data.ranks
                }
            } else if case let .peer(_, peer) = additionalEntry, let channel = peer as? TelegramChannel, !channel.flags.contains(.isGigagroup) {
                channelPeer = channel
                if let defaultBannedRights = channel.defaultBannedRights, defaultBannedRights.flags.contains(.banSendStickers) {
                    stickersEnabled = false
                }
            }
        }
    }
    
    var joinMessage: Message?
    if (associatedData.subject?.isService ?? false) {
        
    } else {
        if case let .peer(peerId) = location, case let cachedData = cachedData as? CachedChannelData, let invitedOn = cachedData?.invitedOn {
            joinMessage = Message(
                stableId: UInt32.max - 1000,
                stableVersion: 0,
                id: MessageId(peerId: peerId, namespace: Namespaces.Message.Local, id: 0),
                globallyUniqueId: nil,
                groupingKey: nil,
                groupInfo: nil,
                threadId: nil,
                timestamp: invitedOn,
                flags: [.Incoming],
                tags: [],
                globalTags: [],
                localTags: [],
                customTags: [],
                forwardInfo: nil,
                author: channelPeer,
                text: "",
                attributes: [],
                media: [TelegramMediaAction(action: .joinedByRequest)],
                peers: SimpleDictionary<PeerId, Peer>(),
                associatedMessages: SimpleDictionary<MessageId, Message>(),
                associatedMessageIds: [],
                associatedMedia: [:],
                associatedThreadInfo: nil,
                associatedStories: [:]
            )
        } else if let peer = channelPeer as? TelegramChannel, case .broadcast = peer.info, case .member = peer.participationStatus, !peer.flags.contains(.isCreator) {
            joinMessage = Message(
                stableId: UInt32.max - 1000,
                stableVersion: 0,
                id: MessageId(peerId: peer.id, namespace: Namespaces.Message.Local, id: 0),
                globallyUniqueId: nil,
                groupingKey: nil,
                groupInfo: nil,
                threadId: nil,
                timestamp: peer.creationDate,
                flags: [.Incoming],
                tags: [],
                globalTags: [],
                localTags: [],
                customTags: [],
                forwardInfo: nil,
                author: channelPeer,
                text: "",
                attributes: [],
                media: [TelegramMediaAction(action: .joinedChannel)],
                peers: SimpleDictionary<PeerId, Peer>(),
                associatedMessages: SimpleDictionary<MessageId, Message>(),
                associatedMessageIds: [],
                associatedMedia: [:],
                associatedThreadInfo: nil,
                associatedStories: [:]
            )
        }
    }
    
    var existingGroupStableIds: [UInt32] = []
    var groupBucket: [(Message, Bool, ChatHistoryMessageSelection, ChatMessageEntryAttributes, MessageHistoryEntryLocation?)] = []
    var count = 0
    loop: for entry in view.entries {
        var message = entry.message
        var isRead = entry.isRead
        
        if pendingRemovedMessages.contains(message.id) {
            continue
        }
        
        if case let .replyThread(replyThreadMessage) = location, replyThreadMessage.isForumPost {
            for media in message.media {
                if let action = media as? TelegramMediaAction, case .topicCreated = action.action {
                    continue loop
                }
            }
        }
        
        count += 1
        
        if let customThreadOutgoingReadState = customThreadOutgoingReadState {
            isRead = customThreadOutgoingReadState >= message.id
        }
        
        if let customChannelDiscussionReadState = customChannelDiscussionReadState {
            attibuteLoop: for i in 0 ..< message.attributes.count {
                if let attribute = message.attributes[i] as? ReplyThreadMessageAttribute {
                    if let maxReadMessageId = attribute.maxReadMessageId {
                        if maxReadMessageId < customChannelDiscussionReadState.id {
                            var attributes = message.attributes
                            attributes[i] = ReplyThreadMessageAttribute(count: attribute.count, latestUsers: attribute.latestUsers, commentsPeerId: attribute.commentsPeerId, maxMessageId: attribute.maxMessageId, maxReadMessageId: customChannelDiscussionReadState.id)
                            message = message.withUpdatedAttributes(attributes)
                        }
                    }
                    break attibuteLoop
                }
            }
        }
        
        if skipViewOnceMedia, message.minAutoremoveOrClearTimeout != nil {
            continue loop
        }
        
        var contentTypeHint: ChatMessageEntryContentType = .generic
        
        for media in message.media {
            if media is TelegramMediaDice {
                contentTypeHint = .animatedEmoji
            }
            if let action = media as? TelegramMediaAction {
                switch action.action {
                    case .channelMigratedFromGroup, .groupMigratedToChannel, .historyCleared:
                        continue loop
                    default:
                        break
                }
            }
        }
    
        var adminRank: CachedChannelAdminRank?
        if let author = message.author {
            adminRank = adminRanks[author.id]
        }
        
        if presentationData.largeEmoji, message.media.isEmpty {
            if messageIsElligibleForLargeCustomEmoji(message) {
                contentTypeHint = .animatedEmoji
            } else if stickersEnabled && message.text.count == 1, let _ = associatedData.animatedEmojiStickers[message.text.basicEmoji.0], (message.textEntitiesAttribute?.entities.isEmpty ?? true) {
                contentTypeHint = .animatedEmoji
            } else if messageIsElligibleForLargeEmoji(message) {
                contentTypeHint = .animatedEmoji
            }
        }
    
        if groupMessages || reverseGroupedMessages {
            if !groupBucket.isEmpty && message.groupInfo != groupBucket[0].0.groupInfo {
                if reverseGroupedMessages {
                    groupBucket.reverse()
                }
                if groupMessages {
                    let groupStableId = groupBucket[0].0.groupInfo!.stableId
                    if !existingGroupStableIds.contains(groupStableId) {
                        existingGroupStableIds.append(groupStableId)
                        entries.append(.MessageGroupEntry(groupBucket[0].0.groupInfo!, groupBucket, presentationData))
                    }
                } else {
                    for (message, isRead, selection, attributes, location) in groupBucket {
                        entries.append(.MessageEntry(message, presentationData, isRead, location, selection, attributes))
                    }
                }
                groupBucket.removeAll()
            }
            if let _ = message.groupInfo {
                let selection: ChatHistoryMessageSelection
                if let selectedMessages = selectedMessages {
                    selection = .selectable(selected: selectedMessages.contains(message.id))
                } else {
                    selection = .none
                }
                groupBucket.append((message, isRead, selection, ChatMessageEntryAttributes(rank: adminRank, isContact: entry.attributes.authorIsContact, contentTypeHint: contentTypeHint, updatingMedia: updatingMedia[message.id], isPlaying: false, isCentered: false, authorStoryStats: message.author.flatMap { view.peerStoryStats[$0.id] }), entry.location))
            } else {
                let selection: ChatHistoryMessageSelection
                if let selectedMessages = selectedMessages {
                    selection = .selectable(selected: selectedMessages.contains(message.id))
                } else {
                    selection = .none
                }
                entries.append(.MessageEntry(message, presentationData, isRead, entry.location, selection, ChatMessageEntryAttributes(rank: adminRank, isContact: entry.attributes.authorIsContact, contentTypeHint: contentTypeHint, updatingMedia: updatingMedia[message.id], isPlaying: message.index == associatedData.currentlyPlayingMessageId, isCentered: false, authorStoryStats: message.author.flatMap { view.peerStoryStats[$0.id] })))
            }
        } else {
            let selection: ChatHistoryMessageSelection
            if let selectedMessages = selectedMessages {
                selection = .selectable(selected: selectedMessages.contains(message.id))
            } else {
                selection = .none
            }
            entries.append(.MessageEntry(message, presentationData, isRead, entry.location, selection, ChatMessageEntryAttributes(rank: adminRank, isContact: entry.attributes.authorIsContact, contentTypeHint: contentTypeHint, updatingMedia: updatingMedia[message.id], isPlaying: message.index == associatedData.currentlyPlayingMessageId, isCentered: false, authorStoryStats: message.author.flatMap { view.peerStoryStats[$0.id] })))
        }
    }
        
    if !groupBucket.isEmpty {
        assert(groupMessages || reverseGroupedMessages)
        if reverseGroupedMessages {
            groupBucket.reverse()
        }
        if groupMessages {
            let groupStableId = groupBucket[0].0.groupInfo!.stableId
            if !existingGroupStableIds.contains(groupStableId) {
                existingGroupStableIds.append(groupStableId)
                entries.append(.MessageGroupEntry(groupBucket[0].0.groupInfo!, groupBucket, presentationData))
            }
        } else {
            for (message, isRead, selection, attributes, location) in groupBucket {
                entries.append(.MessageEntry(message, presentationData, isRead, location, selection, attributes))
            }
        }
    }
    
    if let lowerTimestamp = view.entries.last?.message.timestamp, let upperTimestamp = view.entries.first?.message.timestamp {
        if let joinMessage {
            var insertAtPosition: Int?
            if joinMessage.timestamp >= lowerTimestamp && view.laterId == nil {
                insertAtPosition = entries.count
            } else if joinMessage.timestamp < lowerTimestamp && joinMessage.timestamp > upperTimestamp {
                for i in 0 ..< entries.count {
                    if let timestamp = entries[i].timestamp, timestamp > joinMessage.timestamp {
                        insertAtPosition = i
                        break
                    }
                }
            }
            if let insertAtPosition {
                entries.insert(.MessageEntry(joinMessage, presentationData, false, nil, .none, ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil)), at: insertAtPosition)
            }
        }
    }
        
    if let maxReadIndex = view.maxReadIndex, includeUnreadEntry {
        var i = 0
        let unreadEntry: ChatHistoryEntry = .UnreadEntry(maxReadIndex, presentationData)
        for entry in entries {
            if entry > unreadEntry {
                if i != 0 {
                    entries.insert(unreadEntry, at: i)
                }
                break
            }
            i += 1
        }
    }
    
    var addedThreadHead = false
    if case let .replyThread(replyThreadMessage) = location, !replyThreadMessage.isForumPost, view.earlierId == nil, !view.holeEarlier, !view.isLoading {
        loop: for entry in view.additionalData {
            switch entry {
            case let .message(id, messages) where id == replyThreadMessage.effectiveTopId:
                if !messages.isEmpty {
                    let selection: ChatHistoryMessageSelection = .none
                    
                    let topMessage = messages[0]
                    
                    var hasTopicCreated = false
                    inner: for media in topMessage.media {
                        if let action = media as? TelegramMediaAction {
                            switch action.action {
                                case .topicCreated:
                                    hasTopicCreated = true
                                    break inner
                                default:
                                    break
                            }
                        }
                    }
                    
                    var adminRank: CachedChannelAdminRank?
                    if let author = topMessage.author {
                        adminRank = adminRanks[author.id]
                    }
                    
                    var contentTypeHint: ChatMessageEntryContentType = .generic
                    if presentationData.largeEmoji, topMessage.media.isEmpty {
                        if messageIsElligibleForLargeCustomEmoji(topMessage) {
                            contentTypeHint = .animatedEmoji
                        } else if stickersEnabled && topMessage.text.count == 1, let _ = associatedData.animatedEmojiStickers[topMessage.text.basicEmoji.0] {
                            contentTypeHint = .animatedEmoji
                        } else if messageIsElligibleForLargeEmoji(topMessage) {
                            contentTypeHint = .animatedEmoji
                        }
                    }
                    
                    addedThreadHead = true
                    if messages.count > 1, let groupInfo = messages[0].groupInfo {
                        var groupMessages: [(Message, Bool, ChatHistoryMessageSelection, ChatMessageEntryAttributes, MessageHistoryEntryLocation?)] = []
                        for message in messages {
                            groupMessages.append((message, false, .none, ChatMessageEntryAttributes(rank: adminRank, isContact: false, contentTypeHint: contentTypeHint, updatingMedia: updatingMedia[message.id], isPlaying: false, isCentered: false, authorStoryStats: message.author.flatMap { view.peerStoryStats[$0.id] }), nil))
                        }
                        entries.insert(.MessageGroupEntry(groupInfo, groupMessages, presentationData), at: 0)
                    } else {
                        if !hasTopicCreated {
                            entries.insert(.MessageEntry(messages[0], presentationData, false, nil, selection, ChatMessageEntryAttributes(rank: adminRank, isContact: false, contentTypeHint: contentTypeHint, updatingMedia: updatingMedia[messages[0].id], isPlaying: false, isCentered: false, authorStoryStats: messages[0].author.flatMap { view.peerStoryStats[$0.id] })), at: 0)
                        }
                    }
                    
                    if !replyThreadMessage.isForumPost {
                        let replyCount = view.entries.isEmpty ? 0 : 1
                        entries.insert(.ReplyCountEntry(messages[0].index, replyThreadMessage.isChannelPost, replyCount, presentationData), at: 1)
                    }
                }
                break loop
            default:
                break
            }
        }
    }
    
    if includeChatInfoEntry {
        if view.earlierId == nil, !view.isLoading {
            var cachedPeerData: CachedPeerData?
            for entry in view.additionalData {
                if case let .cachedPeerData(_, data) = entry {
                    cachedPeerData = data
                    break
                }
            }
            if case let .peer(peerId) = location, peerId.isReplies {
                entries.insert(.ChatInfoEntry("", presentationData.strings.RepliesChat_DescriptionText, nil, nil, presentationData), at: 0)
            } else if let cachedPeerData = cachedPeerData as? CachedUserData, let botInfo = cachedPeerData.botInfo, !botInfo.description.isEmpty {
                entries.insert(.ChatInfoEntry(presentationData.strings.Bot_DescriptionTitle, botInfo.description, botInfo.photo, botInfo.video, presentationData), at: 0)
            } else {
                var isEmpty = true
                if entries.count <= 3 {
                    loop: for entry in view.entries {
                        var isEmptyMedia = false
                        var isPeerJoined = false
                        for media in entry.message.media {
                            if let action = media as? TelegramMediaAction {
                                switch action.action {
                                    case .groupCreated, .photoUpdated, .channelMigratedFromGroup, .groupMigratedToChannel:
                                        isEmptyMedia = true
                                    case .peerJoined:
                                        isPeerJoined = true
                                    default:
                                        break
                                }
                            }
                        }
                        var isCreator = false
                        if let peer = entry.message.peers[entry.message.id.peerId] as? TelegramGroup, case .creator = peer.role {
                            isCreator = true
                        } else if let peer = entry.message.peers[entry.message.id.peerId] as? TelegramChannel, case .group = peer.info, peer.flags.contains(.isCreator) {
                            isCreator = true
                        }
                        if isPeerJoined || (isEmptyMedia && isCreator) {
                        } else {
                            isEmpty = false
                            break loop
                        }
                    }
                } else {
                    isEmpty = false
                }
                if addedThreadHead {
                    isEmpty = false
                }
                if isEmpty {
                    entries.removeAll()
                }
            }
        }
        
        if !dynamicAdMessages.isEmpty {
            assert(entries.sorted() == entries)
            for message in dynamicAdMessages {
                entries.append(.MessageEntry(message, presentationData, false, nil, .none, ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil)))
            }
            entries.sort()
        }

        if view.laterId == nil && !view.isLoading {
            if !entries.isEmpty, case let .MessageEntry(lastMessage, _, _, _, _, _) = entries[entries.count - 1], let message = adMessage {
                var nextAdMessageId: Int32 = 10000
                let updatedMessage = Message(
                    stableId: ChatHistoryListNodeImpl.fixedAdMessageStableId,
                    stableVersion: message.stableVersion,
                    id: MessageId(peerId: message.id.peerId, namespace: message.id.namespace, id: nextAdMessageId),
                    globallyUniqueId: nil,
                    groupingKey: nil,
                    groupInfo: nil,
                    threadId: nil,
                    timestamp: lastMessage.timestamp,
                    flags: message.flags,
                    tags: message.tags,
                    globalTags: message.globalTags,
                    localTags: message.localTags,
                    customTags: message.customTags,
                    forwardInfo: message.forwardInfo,
                    author: message.author,
                    text: /*"\(message.adAttribute!.opaqueId.hashValue)" + */message.text,
                    attributes: message.attributes,
                    media: message.media,
                    peers: message.peers,
                    associatedMessages: message.associatedMessages,
                    associatedMessageIds: message.associatedMessageIds,
                    associatedMedia: message.associatedMedia,
                    associatedThreadInfo: message.associatedThreadInfo,
                    associatedStories: message.associatedStories
                )
                nextAdMessageId += 1
                entries.append(.MessageEntry(updatedMessage, presentationData, false, nil, .none, ChatMessageEntryAttributes(rank: nil, isContact: false, contentTypeHint: .generic, updatingMedia: nil, isPlaying: false, isCentered: false, authorStoryStats: nil)))
            }
        }
    } else if includeSearchEntry {
        if view.laterId == nil {
            if !view.entries.isEmpty {
                entries.append(.SearchEntry(presentationData.theme.theme, presentationData.strings))
            }
        }
    }
    
    if reverse {
        return entries.reversed()
    } else {
        return entries
    }
}
