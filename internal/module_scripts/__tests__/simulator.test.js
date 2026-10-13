const { chooseIphone } = require('../simulator');

const ios = (major, minor) => `com.apple.CoreSimulator.SimRuntime.iOS-${major}-${minor}`;
const device = (name, udid, state = 'Shutdown') => ({ name, udid, state });

describe('chooseIphone', () => {
  it('picks an iPhone on the newest iOS runtime', () => {
    const chosen = chooseIphone({
      [ios(18, 6)]: [device('iPhone 16', 'old')],
      [ios(26, 0)]: [device('iPhone 17', 'new')],
    });
    expect(chosen.udid).toBe('new');
  });

  it('prefers a booted iPhone over one on a newer runtime', () => {
    const chosen = chooseIphone({
      [ios(18, 6)]: [device('iPhone 16', 'booted', 'Booted')],
      [ios(26, 0)]: [device('iPhone 17', 'new')],
    });
    expect(chosen.udid).toBe('booted');
  });

  it('compares minor versions numerically', () => {
    const chosen = chooseIphone({
      [ios(26, 9)]: [device('iPhone 17', 'nine')],
      [ios(26, 10)]: [device('iPhone 17', 'ten')],
    });
    expect(chosen.udid).toBe('ten');
  });

  it('ignores iPads and non-iOS runtimes', () => {
    const chosen = chooseIphone({
      [ios(26, 0)]: [device('iPad Pro 13-inch', 'ipad')],
      'com.apple.CoreSimulator.SimRuntime.tvOS-26-0': [device('iPhone 17', 'tv')],
    });
    expect(chosen).toBeNull();
  });

  it('returns null when there are no devices', () => {
    expect(chooseIphone({})).toBeNull();
  });
});
