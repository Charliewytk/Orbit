import XCTest
@testable import OrbitCore

final class TaskOriginTests: XCTestCase {
    private func task(_ source: TaskSource, ref: String? = nil, module: String? = nil, assessment: String? = nil) -> OrbitTask {
        var t = OrbitTask(title: "x", source: source)
        t.sourceRef = ref
        t.moduleCode = module
        t.assessmentID = assessment
        return t
    }

    func testOrigins() {
        XCTAssertEqual(task(.manual).origin, .yours)
        XCTAssertEqual(task(.message).origin, .yours)
        XCTAssertEqual(task(.assistant).origin, .recommended)
        XCTAssertEqual(task(.notes).origin, .recommended)
        XCTAssertEqual(task(.ele, ref: "hw-BEE1022-cm1").origin, .required)
        XCTAssertEqual(task(.ele, assessment: "a1").origin, .required)
        // Reading chunks are filed under ELE but are Orbit's plan.
        XCTAssertEqual(task(.ele, ref: "reading:r1#0").origin, .recommended)
        XCTAssertEqual(task(.manual, ref: "careers:spring-weeks|nomura|x").origin, .recommended)
        XCTAssertEqual(task(.email).origin, .yours)
        XCTAssertEqual(task(.email, module: "BEM2031").origin, .required)
        XCTAssertEqual(TaskOrigin.required.label, "Required")
    }
}
