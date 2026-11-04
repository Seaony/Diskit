import Foundation
import Testing

@testable import Core

@Test func spaceInfoDistinguishesUnknownFromRealZero() {
  let unknown = SpaceInfo(total: nil, used: nil)
  #expect(unknown.total == nil)
  #expect(unknown.used == nil)
  #expect(unknown.available == nil)
  let zero = SpaceInfo(total: 0, used: 0)
  #expect(zero.total == 0)
  #expect(zero.used == 0)
  #expect(zero.available == 0)
  #expect(unknown != zero)
  #expect(SpaceInfo(total: nil, used: 123).used == 123)
  #expect(SpaceInfo(total: nil, used: 123).available == nil)
  #expect(SpaceInfo(total: 456, used: nil).total == 456)
  #expect(SpaceInfo(total: 456, used: nil).available == nil)
  #expect(SpaceInfo(total: nil, used: nil, available: 789).available == 789)
  let reservedBlocks = SpaceInfo(total: 100, used: 40, available: 50)
  #expect(reservedBlocks.used == 40)
  #expect(reservedBlocks.available == 50)
}

@Test func spaceInfoNeverProducesNegativeOrOverflowedAvailableCapacity() {
  #expect(SpaceInfo(total: -1, used: -1) == SpaceInfo(total: nil, used: nil))
  #expect(SpaceInfo(total: 10, used: 20).available == nil)
  #expect(SpaceInfo(total: 10, used: 20).used == 20)
  #expect(SpaceInfo(total: Int64.max, used: 0).available == Int64.max)
  #expect(SpaceInfo(total: 10, used: nil, available: 20).available == nil)
  #expect(SpaceInfo(total: nil, used: nil, available: -1).available == nil)
}
