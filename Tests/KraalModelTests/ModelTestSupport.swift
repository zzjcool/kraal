// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import KraalHC
import KraalModel

func modelWithOne() -> KraalModel {
    var model = KraalModel(home: "/home/me")
    model.addSpace(
        id: "sp1",
        name: "api",
        folder: "/src/api",
        tab: KraalTabSeed(id: "tb1", name: "fix login", paneID: "p1", terminal: "t1")
    )
    return model
}

func parent(of id: String, in node: KraalNode) -> KraalNode? {
    for child in node.children {
        if child.id == id { return node }
        if let found = parent(of: id, in: child) { return found }
    }
    return nil
}

func descendantContainerProblem(_ node: KraalNode, isRoot: Bool = true) -> String? {
    if !isRoot, ["row", "column"].contains(node.type), node.children.count < 2 {
        return "\(node.id) has \(node.children.count) children"
    }
    for child in node.children {
        if let problem = descendantContainerProblem(child, isRoot: false) { return problem }
    }
    return nil
}
