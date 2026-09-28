import Foundation

public enum TrackingTechnology: String, Codable, CaseIterable, Sendable { case barcode, rfid, licensePlate, visionCode }
public enum BufferDiscipline: String, Codable, CaseIterable, Sendable { case fifo, accumulation, laneFIFO, priority }
public enum ArbitrationStrategy: String, Codable, CaseIterable, Sendable { case roundRobin, oldestFirst, priority, recipeFamily }
public enum HandshakeState: String, Codable, CaseIterable, Sendable { case ready, starved, blocked, held, changeover, faulted }
public enum QualityHoldState: String, Codable, CaseIterable, Sendable { case released, held, quarantined, recalled, scrapped }
public enum ChangeoverPhase: String, Codable, CaseIterable, Sendable { case running, drain, clean, mechanicalSetup, recipeDownload, verification, firstPiece, complete }

public struct ProductTrackingIdentity: Codable, Equatable, Sendable {
    public var entityID: String
    public var primaryCode: String
    public var technologies: [TrackingTechnology: String]
    public var palletLicensePlate: String?
    public init(entityID: String, primaryCode: String, technologies: [TrackingTechnology: String] = [:], palletLicensePlate: String? = nil) {
        self.entityID=entityID;self.primaryCode=primaryCode;self.technologies=technologies;self.palletLicensePlate=palletLicensePlate
    }
}

public struct ProductionRecipe: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var sku: String
    public var revision: Int
    public var description: String
    public var parameters: [String: Double]
    public var labels: [String: String]
    public init(id:String,sku:String,revision:Int=1,description:String,parameters:[String:Double]=[:],labels:[String:String]=[:]){self.id=id;self.sku=sku;self.revision=revision;self.description=description;self.parameters=parameters;self.labels=labels}
}

public struct GenealogyEvent: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var entityID: String
    public var timestamp: Double
    public var machine: PlayableMachineKind?
    public var zoneID: String?
    public var event: String
    public var lotIDs: [String]
    public var recipeID: String?
    public var data: [String: String]
    public init(entityID:String,timestamp:Double,machine:PlayableMachineKind?=nil,zoneID:String?=nil,event:String,lotIDs:[String]=[],recipeID:String?=nil,data:[String:String]=[:]){self.entityID=entityID;self.timestamp=timestamp;self.machine=machine;self.zoneID=zoneID;self.event=event;self.lotIDs=lotIDs;self.recipeID=recipeID;self.data=data}
}

public struct EntityGenealogyRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: String { identity.entityID }
    public var identity: ProductTrackingIdentity
    public var recipeID: String?
    public var inputLots: [String]
    public var parentEntityIDs: [String]
    public var childEntityIDs: [String]
    public var events: [GenealogyEvent]
    public var holdState: QualityHoldState
    public var rejectReason: String?
    public init(identity:ProductTrackingIdentity,recipeID:String?=nil,inputLots:[String]=[],parentEntityIDs:[String]=[],childEntityIDs:[String]=[],events:[GenealogyEvent]=[],holdState:QualityHoldState = .released,rejectReason:String?=nil){self.identity=identity;self.recipeID=recipeID;self.inputLots=inputLots;self.parentEntityIDs=parentEntityIDs;self.childEntityIDs=childEntityIDs;self.events=events;self.holdState=holdState;self.rejectReason=rejectReason}
}

public struct RejectRecord: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var entityID:String
    public var machine:PlayableMachineKind
    public var timestamp:Double
    public var reason:String
    public var destination:String
    public var confirmed:Bool
    public init(entityID:String,machine:PlayableMachineKind,timestamp:Double,reason:String,destination:String="Reject Lane",confirmed:Bool=false){self.entityID=entityID;self.machine=machine;self.timestamp=timestamp;self.reason=reason;self.destination=destination;self.confirmed=confirmed}
}

public struct LineHandshake: Identifiable, Codable, Equatable, Sendable {
    public var id:String
    public var upstream:PlayableMachineKind
    public var downstream:PlayableMachineKind
    public var upstreamState:HandshakeState
    public var downstreamState:HandshakeState
    public var requestToSend:Bool
    public var permissionToReceive:Bool
    public var lineSpeedReference:Double
    public var interlockHealthy:Bool
    public var reason:String?
    public init(id:String,upstream:PlayableMachineKind,downstream:PlayableMachineKind,upstreamState:HandshakeState = .ready,downstreamState:HandshakeState = .ready,requestToSend:Bool=false,permissionToReceive:Bool=true,lineSpeedReference:Double=100,interlockHealthy:Bool=true,reason:String?=nil){self.id=id;self.upstream=upstream;self.downstream=downstream;self.upstreamState=upstreamState;self.downstreamState=downstreamState;self.requestToSend=requestToSend;self.permissionToReceive=permissionToReceive;self.lineSpeedReference=lineSpeedReference;self.interlockHealthy=interlockHealthy;self.reason=reason}
}

public struct ConveyorZoneControl: Identifiable, Codable, Equatable, Sendable {
    public var id:String
    public var machine:PlayableMachineKind
    public var zoneID:String
    public var occupied:Bool
    public var downstreamClear:Bool
    public var motorCommand:Bool
    public var releasePermission:Bool
    public var accumulationMode:Bool
    public init(id:String,machine:PlayableMachineKind,zoneID:String,occupied:Bool=false,downstreamClear:Bool=true,motorCommand:Bool=false,releasePermission:Bool=true,accumulationMode:Bool=true){self.id=id;self.machine=machine;self.zoneID=zoneID;self.occupied=occupied;self.downstreamClear=downstreamClear;self.motorCommand=motorCommand;self.releasePermission=releasePermission;self.accumulationMode=accumulationMode}
}

public struct OEEAccumulator: Codable, Equatable, Sendable {
    public var scheduledSeconds:Double=0
    public var runningSeconds:Double=0
    public var idealCycleSeconds:Double
    public var totalCount:Int=0
    public var goodCount:Int=0
    public var plannedStopSeconds:Double=0
    public init(idealCycleSeconds:Double){self.idealCycleSeconds=max(0.001,idealCycleSeconds)}
    public var availability:Double { scheduledSeconds > 0 ? min(1,runningSeconds/max(0.001,scheduledSeconds-plannedStopSeconds)) : 0 }
    public var performance:Double { runningSeconds > 0 ? min(1,(Double(totalCount)*idealCycleSeconds)/runningSeconds) : 0 }
    public var quality:Double { totalCount > 0 ? Double(goodCount)/Double(totalCount) : 0 }
    public var oee:Double { availability*performance*quality }
}

public struct ChangeoverState: Codable, Equatable, Sendable {
    public var fromSKU:String?
    public var toSKU:String
    public var phase:ChangeoverPhase
    public var elapsedSeconds:Double
    public var targetSeconds:Double
    public var firstPieceApproved:Bool
    public init(fromSKU:String?,toSKU:String,targetSeconds:Double=300){self.fromSKU=fromSKU;self.toSKU=toSKU;self.phase = .drain;self.elapsedSeconds=0;self.targetSeconds=targetSeconds;self.firstPieceApproved=false}
}

public struct QualityHold: Identifiable, Codable, Equatable, Sendable {
    public var id=UUID().uuidString
    public var scope:String
    public var reason:String
    public var entityIDs:[String]
    public var lotIDs:[String]
    public var createdAt:Double
    public var state:QualityHoldState
    public init(scope:String,reason:String,entityIDs:[String]=[],lotIDs:[String]=[],createdAt:Double,state:QualityHoldState = .held){self.scope=scope;self.reason=reason;self.entityIDs=entityIDs;self.lotIDs=lotIDs;self.createdAt=createdAt;self.state=state}
}

public struct RecallResult: Codable, Equatable, Sendable {
    public var lotID:String
    public var affectedEntityIDs:[String]
    public var downstreamEntities:[String]
    public var machines:[PlayableMachineKind]
}

public struct LineBuilderNode: Identifiable, Codable, Equatable, Sendable {
    public var id:String
    public var machine:PlayableMachineKind
    public var name:String
    public var x:Double
    public var y:Double
    public init(id:String=UUID().uuidString,machine:PlayableMachineKind,name:String?=nil,x:Double=0,y:Double=0){self.id=id;self.machine=machine;self.name=name ?? machine.rawValue;self.x=x;self.y=y}
}

public struct LineBuilderConnection: Identifiable, Codable, Equatable, Sendable {
    public var id:String
    public var fromNodeID:String
    public var toNodeID:String
    public var capacity:Int
    public var discipline:BufferDiscipline
    public var priority:Int
    public init(id:String=UUID().uuidString,fromNodeID:String,toNodeID:String,capacity:Int=8,discipline:BufferDiscipline = .fifo,priority:Int=0){self.id=id;self.fromNodeID=fromNodeID;self.toNodeID=toNodeID;self.capacity=max(1,capacity);self.discipline=discipline;self.priority=priority}
}

public struct LineBuilderProject: Identifiable, Codable, Equatable, Sendable {
    public var id:String
    public var name:String
    public var nodes:[LineBuilderNode]
    public var connections:[LineBuilderConnection]
    public init(id:String=UUID().uuidString,name:String="New Manufacturing Line",nodes:[LineBuilderNode]=[],connections:[LineBuilderConnection]=[]){self.id=id;self.name=name;self.nodes=nodes;self.connections=connections}
    public mutating func addMachine(_ machine:PlayableMachineKind,name:String?=nil,x:Double=0,y:Double=0)->LineBuilderNode { let n=LineBuilderNode(machine:machine,name:name,x:x,y:y);nodes.append(n);return n }
    @discardableResult public mutating func connect(_ from:String,_ to:String,capacity:Int=8,discipline:BufferDiscipline = .fifo,priority:Int=0)->LineBuilderConnection { let c=LineBuilderConnection(fromNodeID:from,toNodeID:to,capacity:capacity,discipline:discipline,priority:priority);connections.append(c);return c }
    public func validationIssues()->[String] {
        var issues:[String]=[];let ids=Set(nodes.map(\.id));var seen=Set<String>()
        for c in connections { if !ids.contains(c.fromNodeID) || !ids.contains(c.toNodeID){issues.append("Connection \(c.id) references a missing node.")};if c.fromNodeID==c.toNodeID{issues.append("Machine cannot connect to itself.")};let k="\(c.fromNodeID)>\(c.toNodeID)";if !seen.insert(k).inserted{issues.append("Duplicate connection \(k).")}}
        return issues
    }
}

public struct IntelligentLineBuffer: Identifiable, Codable, Equatable, Sendable {
    public var id:String
    public var connection:LineBuilderConnection
    public var entities:[MaterialEntity]=[]
    public var mergeToken:Int=0
    public init(connection:LineBuilderConnection){self.id=connection.id;self.connection=connection}
    public mutating func enqueue(_ entities:[MaterialEntity]) { self.entities.append(contentsOf:entities); if connection.discipline == .priority { self.entities.sort{($0.attributes["priority"] ?? 0) > ($1.attributes["priority"] ?? 0)} } else { self.entities.sort{$0.createdAt < $1.createdAt} } }
    public mutating func dequeue()->MaterialEntity? { entities.isEmpty ? nil : entities.removeFirst() }
}

public struct ProductionIntelligenceSnapshot: Sendable {
    public var elapsedSeconds:Double
    public var genealogy:[String:EntityGenealogyRecord]
    public var rejects:[RejectRecord]
    public var handshakes:[String:LineHandshake]
    public var machineOEE:[PlayableMachineKind:OEEAccumulator]
    public var lineOEE:OEEAccumulator
    public var holds:[QualityHold]
    public var buffers:[String:Int]
    public var machineSnapshots:[PlayableMachineKind:FullyClosedLoopSnapshot]
}

public struct ProductionIntelligenceRuntime: Sendable {
    public var project:LineBuilderProject
    public var machines:[String:FullyClosedLoopMachineRuntime]
    public var buffers:[String:IntelligentLineBuffer]
    public var genealogy:[String:EntityGenealogyRecord]=[:]
    public var rejects:[RejectRecord]=[]
    public var handshakes:[String:LineHandshake]=[:]
    public var conveyorZones:[String:ConveyorZoneControl]=[:]
    public var recipes:[String:ProductionRecipe]=[:]
    public var activeRecipeByNode:[String:String]=[:]
    public var changeovers:[String:ChangeoverState]=[:]
    public var mergeStrategyByNode:[String:ArbitrationStrategy]=[:]
    public var holds:[QualityHold]=[]
    public var machineOEE:[PlayableMachineKind:OEEAccumulator]=[:]
    public var elapsedSeconds:Double=0
    private var lastCompleted:[String:Int]=[:]
    private var roundRobinCursor:[String:Int]=[:]

    public init(project:LineBuilderProject) throws {
        let issues=project.validationIssues();guard issues.isEmpty else{throw ProductionIntelligenceError.invalidLine(issues.joined(separator:" "))}
        self.project=project;self.machines=[:];self.buffers=[:]
        for n in project.nodes { machines[n.id]=try FullyClosedLoopMachineRuntime(machine:n.machine);machineOEE[n.machine]=OEEAccumulator(idealCycleSeconds:MachineMaterialFlowLibrary.profile(n.machine).nominalFeedInterval);lastCompleted[n.id]=0
            for z in MachineMaterialFlowLibrary.profile(n.machine).zones { conveyorZones["\(n.id):\(z.id)"]=ConveyorZoneControl(id:"\(n.id):\(z.id)",machine:n.machine,zoneID:z.id,accumulationMode:z.allowsAccumulation) }
        }
        for c in project.connections {
            buffers[c.id]=IntelligentLineBuffer(connection:c)
            if let u=project.nodes.first(where:{$0.id==c.fromNodeID}),let d=project.nodes.first(where:{$0.id==c.toNodeID}) { handshakes[c.id]=LineHandshake(id:c.id,upstream:u.machine,downstream:d.machine) }
        }
        let receiving=Set(project.connections.map(\.toNodeID));for id in receiving{machines[id]?.materialFlow.externalFeedEnabled=false}
    }

    public mutating func registerRecipe(_ recipe:ProductionRecipe){recipes[recipe.id]=recipe}
    public mutating func setRecipe(_ recipeID:String,on nodeID:String){guard recipes[recipeID] != nil else{return};activeRecipeByNode[nodeID]=recipeID}
    public mutating func beginChangeover(nodeID:String,toSKU:String,targetSeconds:Double=300){let current=activeRecipeByNode[nodeID].flatMap{recipes[$0]?.sku};changeovers[nodeID]=ChangeoverState(fromSKU:current,toSKU:toSKU,targetSeconds:targetSeconds);machines[nodeID]?.materialFlow.externalFeedEnabled=false}
    public mutating func setMergeStrategy(_ strategy: ArbitrationStrategy, for nodeID: String) { mergeStrategyByNode[nodeID] = strategy }
    public mutating func approveFirstPiece(nodeID:String){changeovers[nodeID]?.firstPieceApproved=true;if changeovers[nodeID]?.phase == .firstPiece{changeovers[nodeID]?.phase = .complete}}

    @discardableResult public mutating func cycle(elapsedMilliseconds:Int32=100)throws->ProductionIntelligenceSnapshot {
        let dt=Double(elapsedMilliseconds)/1000;elapsedSeconds += dt;updateChangeovers(dt)
        var snapshots:[PlayableMachineKind:FullyClosedLoopSnapshot]=[:]
        for n in project.nodes {
            guard var r=machines[n.id] else{continue};let snap=try r.cycle(elapsedMilliseconds:elapsedMilliseconds);machines[n.id]=r;snapshots[n.machine]=snap
            captureEntities(node:n,runtime:r);updateZoneControl(node:n,runtime:r);updateOEE(node:n,runtime:r,dt:dt)
        }
        collectCompleted();transferBuffers();updateHandshakes();propagateRecipesAndHolds()
        return .init(elapsedSeconds:elapsedSeconds,genealogy:genealogy,rejects:rejects,handshakes:handshakes,machineOEE:machineOEE,lineOEE:lineOEE(),holds:holds,buffers:buffers.mapValues{$0.entities.count},machineSnapshots:snapshots)
    }

    public mutating func placeHold(entityIDs:[String]=[],lotIDs:[String]=[],reason:String)->QualityHold { let h=QualityHold(scope:lotIDs.isEmpty ? "entity":"lot",reason:reason,entityIDs:entityIDs,lotIDs:lotIDs,createdAt:elapsedSeconds);holds.append(h);for id in affected(entityIDs:entityIDs,lotIDs:lotIDs){genealogy[id]?.holdState = .held};return h }
    public mutating func releaseHold(_ id:String){guard let i=holds.firstIndex(where:{$0.id==id})else{return};holds[i].state = .released;for e in holds[i].entityIDs{genealogy[e]?.holdState = .released}}
    public mutating func recall(lotID:String,reason:String)->RecallResult { let ids=affected(entityIDs:[],lotIDs:[lotID]);for id in ids{genealogy[id]?.holdState = .recalled};holds.append(.init(scope:"recall",reason:reason,lotIDs:[lotID],createdAt:elapsedSeconds,state:.recalled));let machines=Set(ids.flatMap{genealogy[$0]?.events.compactMap(\.machine) ?? []});return .init(lotID:lotID,affectedEntityIDs:ids,downstreamEntities:descendants(of:ids),machines:Array(machines)) }
    public func genealogyTrace(entityID:String)->[GenealogyEvent]{genealogy[entityID]?.events.sorted{$0.timestamp<$1.timestamp} ?? []}

    private mutating func captureEntities(node:LineBuilderNode,runtime:FullyClosedLoopMachineRuntime){
        let all=runtime.materialFlow.entities+runtime.materialFlow.completed+runtime.materialFlow.rework+runtime.materialFlow.scrapped
        for e in all {
            if genealogy[e.id] == nil { let identity=trackingIdentity(for:e);let recipe=activeRecipeByNode[node.id];let lots=lotIDs(for:e);genealogy[e.id]=EntityGenealogyRecord(identity:identity,recipeID:recipe,inputLots:lots,events:[.init(entityID:e.id,timestamp:elapsedSeconds,machine:node.machine,zoneID:e.zoneID,event:"Tracking identity created",lotIDs:lots,recipeID:recipe)]) }
            if genealogy[e.id]?.events.last?.zoneID != e.zoneID {
                let lots = genealogy[e.id]?.inputLots ?? []
                let recipe = genealogy[e.id]?.recipeID
                genealogy[e.id]?.events.append(.init(entityID:e.id,timestamp:elapsedSeconds,machine:node.machine,zoneID:e.zoneID,event:"Entered \(e.zoneID)",lotIDs:lots,recipeID:recipe))
            }
        }
        for e in runtime.materialFlow.scrapped where genealogy[e.id]?.rejectReason == nil { genealogy[e.id]?.rejectReason="Machine quality gate reject";genealogy[e.id]?.holdState = .scrapped;rejects.append(.init(entityID:e.id,machine:node.machine,timestamp:elapsedSeconds,reason:"Machine quality gate reject")) }
    }
    private mutating func collectCompleted() {
        for node in project.nodes {
            guard var runtime = machines[node.id] else { continue }
            let outgoing = project.connections.filter { $0.fromNodeID == node.id }
            guard !outgoing.isEmpty else { continue }
            let available = max(0, outgoing.reduce(0) { sum, connection in
                sum + (buffers[connection.id].map { $0.connection.capacity - $0.entities.count } ?? 0)
            })
            if available > 0 {
                let entities = runtime.materialFlow.takeCompleted(limit: available)
                for entity in entities {
                    if let connection = chooseConnection(for: entity, from: node.id, candidates: outgoing) {
                        buffers[connection.id]?.enqueue([entity])
                        let lots = genealogy[entity.id]?.inputLots ?? []
                        let recipe = genealogy[entity.id]?.recipeID
                        genealogy[entity.id]?.events.append(.init(entityID: entity.id, timestamp: elapsedSeconds, machine: node.machine, event: "Transferred to buffer \(connection.id)", lotIDs: lots, recipeID: recipe))
                    } else {
                        runtime.materialFlow.completed.append(entity)
                    }
                }
            }
            machines[node.id] = runtime
        }
    }

    private mutating func transferBuffers() {
        let downstreamIDs = Array(Set(project.connections.map(\.toNodeID)))
        for downstreamID in downstreamIDs {
            guard var downstream = machines[downstreamID], let downstreamNode = project.nodes.first(where: { $0.id == downstreamID }) else { continue }
            let incoming = project.connections.filter { $0.toNodeID == downstreamID }
            var guardCount = 0
            while guardCount < incoming.reduce(0, { $0 + (buffers[$1.id]?.entities.count ?? 0) }) + 1 {
                guardCount += 1
                let candidates = incoming.filter { connection in
                    guard let first = buffers[connection.id]?.entities.first else { return false }
                    let state = genealogy[first.id]?.holdState ?? .released
                    return state != .held && state != .recalled && state != .quarantined
                }
                guard let selected = selectIncoming(candidates, downstreamID: downstreamID), var buffer = buffers[selected.id], let first = buffer.entities.first else { break }
                var entity = first
                guard downstream.materialFlow.enqueue(entity) else { break }
                _ = buffer.dequeue()
                entity.labels["upstreamNode"] = selected.fromNodeID
                entity.labels["downstreamNode"] = selected.toNodeID
                let lots = genealogy[entity.id]?.inputLots ?? []
                let recipe = genealogy[entity.id]?.recipeID
                genealogy[entity.id]?.events.append(.init(entityID: entity.id, timestamp: elapsedSeconds, machine: downstreamNode.machine, zoneID: downstream.materialFlow.profile.zones.first?.id, event: "Received from \(selected.id)", lotIDs: lots, recipeID: recipe))
                buffers[selected.id] = buffer
            }
            downstream.materialFlow.externalFeedEnabled = false
            machines[downstreamID] = downstream
        }
    }

    private mutating func selectIncoming(_ candidates: [LineBuilderConnection], downstreamID: String) -> LineBuilderConnection? {
        guard !candidates.isEmpty else { return nil }
        let strategy = mergeStrategyByNode[downstreamID] ?? .roundRobin
        switch strategy {
        case .oldestFirst:
            return candidates.min { a, b in
                (buffers[a.id]?.entities.first?.createdAt ?? .greatestFiniteMagnitude) < (buffers[b.id]?.entities.first?.createdAt ?? .greatestFiniteMagnitude)
            }
        case .priority:
            return candidates.max { $0.priority < $1.priority }
        case .recipeFamily:
            let active = activeRecipeByNode[downstreamID]
            return candidates.first { c in
                guard let id = buffers[c.id]?.entities.first?.id else { return false }
                return genealogy[id]?.recipeID == active
            } ?? candidates.first
        case .roundRobin:
            let index = roundRobinCursor["merge:\(downstreamID)", default: 0] % candidates.count
            roundRobinCursor["merge:\(downstreamID)"] = index + 1
            return candidates[index]
        }
    }

    private mutating func chooseConnection(for entity: MaterialEntity, from nodeID: String, candidates: [LineBuilderConnection]) -> LineBuilderConnection? {
        let open = candidates.filter { (buffers[$0.id]?.entities.count ?? $0.capacity) < $0.capacity }
        guard !open.isEmpty else { return nil }
        if let destination = entity.labels["destination"], let match = open.first(where: { connection in
            project.nodes.first(where: { $0.id == connection.toNodeID })?.name == destination
        }) { return match }
        let prioritized = open.sorted { $0.priority > $1.priority }
        if prioritized.first?.priority != prioritized.last?.priority { return prioritized.first }
        let index = roundRobinCursor[nodeID, default: 0] % open.count
        roundRobinCursor[nodeID] = index + 1
        return open[index]
    }

    private mutating func updateHandshakes() {
        for connection in project.connections {
            guard let upstream = machines[connection.fromNodeID], let downstream = machines[connection.toNodeID],
                  let upstreamNode = project.nodes.first(where: { $0.id == connection.fromNodeID }),
                  let downstreamNode = project.nodes.first(where: { $0.id == connection.toNodeID }) else { continue }
            let count = buffers[connection.id]?.entities.count ?? 0
            let full = count >= connection.capacity
            let downstreamFull = downstream.materialFlow.entities.count >= downstream.materialFlow.profile.maximumWIP
            let upstreamHasProduct = !upstream.materialFlow.completed.isEmpty || count > 0
            let changingOver = changeovers[connection.toNodeID].map { $0.phase != .complete } ?? false
            handshakes[connection.id] = .init(
                id: connection.id,
                upstream: upstreamNode.machine,
                downstream: downstreamNode.machine,
                upstreamState: full ? .blocked : (upstreamHasProduct ? .ready : .starved),
                downstreamState: changingOver ? .changeover : (downstreamFull ? .blocked : (count == 0 ? .starved : .ready)),
                requestToSend: upstreamHasProduct,
                permissionToReceive: !full && !downstreamFull && !changingOver,
                lineSpeedReference: synchronizedSpeed(up: upstream, down: downstream, bufferCount: count, capacity: connection.capacity),
                interlockHealthy: !changingOver,
                reason: changingOver ? "Downstream changeover active" : (full ? "Inter-machine buffer full" : nil)
            )
        }
    }

    private mutating func updateZoneControl(node: LineBuilderNode, runtime: FullyClosedLoopMachineRuntime) {
        for zone in runtime.materialFlow.profile.zones {
            let key = "\(node.id):\(zone.id)"
            let count = runtime.materialFlow.entities.filter { $0.zoneID == zone.id }.count
            let downstreamClear = count < zone.capacity
            conveyorZones[key] = .init(id: key, machine: node.machine, zoneID: zone.id, occupied: count > 0, downstreamClear: downstreamClear, motorCommand: count > 0 && downstreamClear, releasePermission: downstreamClear, accumulationMode: zone.allowsAccumulation)
        }
    }

    private mutating func updateOEE(node: LineBuilderNode, runtime: FullyClosedLoopMachineRuntime, dt: Double) {
        var accumulator = machineOEE[node.machine] ?? .init(idealCycleSeconds: runtime.materialFlow.profile.nominalFeedInterval)
        accumulator.scheduledSeconds += dt
        let changingOver = changeovers[node.id].map { $0.phase != .complete } ?? false
        if changingOver { accumulator.plannedStopSeconds += dt }
        else if runtime.latestCycle?.jammed != true && runtime.latestCycle?.collisionInterlock != true { accumulator.runningSeconds += dt }
        let total = runtime.materialFlow.completed.count + runtime.materialFlow.rework.count + runtime.materialFlow.scrapped.count
        let previous = lastCompleted[node.id] ?? 0
        if total > previous {
            let delta = total - previous
            accumulator.totalCount += delta
            accumulator.goodCount += min(delta, runtime.materialFlow.completed.count)
            lastCompleted[node.id] = total
        }
        machineOEE[node.machine] = accumulator
    }

    private mutating func updateChangeovers(_ dt: Double) {
        for id in Array(changeovers.keys) {
            guard var changeover = changeovers[id] else { continue }
            changeover.elapsedSeconds += dt
            let segment = max(0.01, changeover.targetSeconds / 6)
            switch changeover.phase {
            case .drain where changeover.elapsedSeconds >= segment: changeover.phase = .clean
            case .clean where changeover.elapsedSeconds >= segment * 2: changeover.phase = .mechanicalSetup
            case .mechanicalSetup where changeover.elapsedSeconds >= segment * 3: changeover.phase = .recipeDownload
            case .recipeDownload where changeover.elapsedSeconds >= segment * 4: changeover.phase = .verification
            case .verification where changeover.elapsedSeconds >= segment * 5: changeover.phase = .firstPiece
            case .firstPiece where changeover.firstPieceApproved: changeover.phase = .complete
            case .complete: machines[id]?.materialFlow.externalFeedEnabled = true
            default: break
            }
            changeovers[id] = changeover
        }
    }

    private mutating func propagateRecipesAndHolds() {
        for (id, record) in genealogy {
            if record.recipeID == nil, let event = record.events.last, let node = project.nodes.first(where: { $0.machine == event.machine }), let recipe = activeRecipeByNode[node.id] {
                genealogy[id]?.recipeID = recipe
            }
        }
    }

    private func lineOEE()->OEEAccumulator { guard !machineOEE.isEmpty else{return .init(idealCycleSeconds:1)};var o=OEEAccumulator(idealCycleSeconds:machineOEE.values.map(\.idealCycleSeconds).reduce(0,+)/Double(machineOEE.count));o.scheduledSeconds=machineOEE.values.map(\.scheduledSeconds).min() ?? 0;o.runningSeconds=machineOEE.values.map(\.runningSeconds).min() ?? 0;o.totalCount=machineOEE.values.map(\.totalCount).min() ?? 0;o.goodCount=machineOEE.values.map(\.goodCount).min() ?? 0;o.plannedStopSeconds=machineOEE.values.map(\.plannedStopSeconds).max() ?? 0;return o }
    private func trackingIdentity(for e:MaterialEntity)->ProductTrackingIdentity { let code=e.labels["barcode"] ?? e.serial;var tech:[TrackingTechnology:String]=[.barcode:code];if [.pallet,.batteryCell,.carrier].contains(e.kind){tech[.rfid]="RFID-\(e.serial)"};let lpn=e.kind == .pallet ? "LPN-\(e.serial)":nil;return .init(entityID:e.id,primaryCode:code,technologies:tech,palletLicensePlate:lpn) }
    private func lotIDs(for e:MaterialEntity)->[String] { var ids=e.labels.filter{$0.key.lowercased().contains("lot")}.map(\.value);if let batch=e.labels["batch"]{ids.append(batch)};if ids.isEmpty{ids=["LOT-\(String(e.serial.prefix(8)))"]};return Array(Set(ids)).sorted() }
    private func affected(entityIDs:[String],lotIDs:[String])->[String]{Array(Set(entityIDs+genealogy.compactMap{lotIDs.isEmpty ? nil:(!$0.value.inputLots.filter{lotIDs.contains($0)}.isEmpty ? $0.key:nil)})).sorted()}
    private func descendants(of roots:[String])->[String]{var seen=Set(roots),queue=roots;while !queue.isEmpty{let x=queue.removeFirst();for child in genealogy[x]?.childEntityIDs ?? [] where seen.insert(child).inserted{queue.append(child)}};return Array(seen.subtracting(Set(roots))).sorted()}
    private func synchronizedSpeed(up:FullyClosedLoopMachineRuntime,down:FullyClosedLoopMachineRuntime,bufferCount:Int,capacity:Int)->Double { let fill=Double(bufferCount)/Double(max(1,capacity));let upNom=100.0,downNom=100.0;if fill>0.8{return min(upNom,70)};if fill<0.2{return min(upNom,downNom)*90/100};return min(upNom,downNom) }
}

public enum ProductionIntelligenceError: Error, Equatable, Sendable { case invalidLine(String) }

public enum ProductionLineTemplates {
    public static var packagingToPalletizing:LineBuilderProject { var p=LineBuilderProject(name:"Packaging & Palletizing");let a=p.addMachine(.packagingCell,x:80,y:140);let b=p.addMachine(.roboticPalletizer,x:420,y:140);p.connect(a.id,b.id,capacity:12,discipline:.accumulation);return p }
    public static var beverageLine:LineBuilderProject { var p=LineBuilderProject(name:"Beverage Filling & Pasteurization");let a=p.addMachine(.batchMixingTank,x:60,y:120);let b=p.addMachine(.htstPasteurizer,x:330,y:120);let c=p.addMachine(.bottlingLine,x:600,y:120);p.connect(a.id,b.id,capacity:16);p.connect(b.id,c.id,capacity:24,discipline:.accumulation);return p }
    public static var warehouseLine:LineBuilderProject { var p=LineBuilderProject(name:"Parcel & AS/RS");let a=p.addMachine(.parcelSortation,x:70,y:120);let b=p.addMachine(.asrsCrane,x:420,y:120);p.connect(a.id,b.id,capacity:20,discipline:.priority);return p }
}
