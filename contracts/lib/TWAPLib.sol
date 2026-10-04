// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// @notice Observation ring buffer and TWAP computation shared by the metric oracle and the index oracle.
// Values are 18-decimal fixed point, the cumulative is value-seconds.
library TWAPLib {
    struct Observation {
        uint64 timestamp;
        uint256 cumulative;
        uint256 value;
    }

    struct State {
        Observation[] observations;
        uint16 capacity;
        uint16 nextIndex;
        uint64 lastTimestamp;
        uint256 lastValue;
        uint256 cumulative;
    }

    error NoObservations();
    error InsufficientHistory();
    error TimestampNotMonotonic();
    error InvalidCapacity();

    // @notice Append an observation. The first write starts the series, later writes must carry a strictly increasing timestamp.
    // Once the buffer holds `capacity` observations the oldest slot is overwritten.
    // The capacity is fixed by the first write.
    function write(State storage self, uint256 value, uint64 timestamp, uint16 capacity) internal {
        if (capacity == 0) revert InvalidCapacity();
        if (self.lastTimestamp == 0) {
            self.capacity = capacity;
            self.observations.push(Observation({ timestamp: timestamp, cumulative: 0, value: value }));
            self.nextIndex = uint16(1 % capacity);
        } else {
            if (timestamp <= self.lastTimestamp) revert TimestampNotMonotonic();
            self.cumulative += self.lastValue * (timestamp - self.lastTimestamp);
            Observation memory obs =
                Observation({ timestamp: timestamp, cumulative: self.cumulative, value: value });
            if (self.observations.length < capacity) {
                self.observations.push(obs);
                self.nextIndex = uint16(self.observations.length % capacity);
            } else {
                self.observations[self.nextIndex] = obs;
                self.nextIndex = uint16((uint256(self.nextIndex) + 1) % capacity);
            }
        }
        self.lastTimestamp = timestamp;
        self.lastValue = value;
    }

    /// @notice Time-weighted average over `window` seconds ending at `nowTs`,
    /// clamped to the available history. Reverts when less than `minWindow`
    /// seconds of history exist.
    function getTWAP(State storage self, uint64 window, uint64 minWindow, uint64 nowTs)
        internal
        view
        returns (uint256)
    {
        if (self.observations.length == 0) revert NoObservations();
        uint64 oldest = _obs(self, 0).timestamp;
        if (nowTs <= oldest) revert InsufficientHistory();
        uint256 available = uint256(nowTs - oldest);
        uint256 effective = window < available ? window : available;
        if (effective < minWindow) revert InsufficientHistory();

        uint256 cumNow =
            nowTs > self.lastTimestamp ? self.cumulative + self.lastValue * (nowTs - self.lastTimestamp) : self.cumulative;
        uint256 cumStart = effective == available ? _obs(self, 0).cumulative : cumulativeAt(self, uint64(nowTs - effective));
        return (cumNow - cumStart) / effective;
    }

    /// @notice Value-seconds accumulated up to `target`, interpolated between
    /// the surrounding observations and clamped to the oldest observation.
    function cumulativeAt(State storage self, uint64 target) internal view returns (uint256) {
        Observation storage o = _surrounding(self, target);
        if (target <= o.timestamp) {
            return o.cumulative;
        }
        return o.cumulative + o.value * (target - o.timestamp);
    }

    function oldestTimestamp(State storage self) internal view returns (uint64) {
        if (self.observations.length == 0) revert NoObservations();
        return _obs(self, 0).timestamp;
    }

    function latestValue(State storage self) internal view returns (uint256) {
        return self.lastValue;
    }

    function latestTimestamp(State storage self) internal view returns (uint64) {
        return self.lastTimestamp;
    }

    function observationCount(State storage self) internal view returns (uint256) {
        return self.observations.length;
    }

    /// @dev Physical slot for a logical position: 0 is the oldest observation,
    /// `length - 1` the newest. Slots wrap once the buffer is full.
    function _physical(State storage self, uint256 logical) private view returns (uint256) {
        uint256 len = self.observations.length;
        if (len < self.capacity) {
            return logical;
        }
        return (uint256(self.nextIndex) + logical) % len;
    }

    function _obs(State storage self, uint256 logical) private view returns (Observation storage) {
        return self.observations[_physical(self, logical)];
    }

    /// @dev Greatest observation whose timestamp is at or before `target`,
    /// clamped to the buffer ends.
    function _surrounding(State storage self, uint64 target) private view returns (Observation storage) {
        uint256 len = self.observations.length;
        Observation storage newest = _obs(self, len - 1);
        if (target >= newest.timestamp) {
            return newest;
        }
        Observation storage oldest = _obs(self, 0);
        if (target <= oldest.timestamp) {
            return oldest;
        }
        uint256 lo = 0;
        uint256 hi = len - 1;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (_obs(self, mid).timestamp <= target) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        return _obs(self, lo);
    }
}