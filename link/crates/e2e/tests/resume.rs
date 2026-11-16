//! The phone link under faults, with the real cores and a simulated network.

use dsbot_link_client::LinkStatus;
use dsbot_link_e2e::{Net, Side};

const GRACE: u64 = 120_000;

fn paired() -> Net {
    let mut net = Net::new(GRACE);
    net.add_phone();
    net.start();
    assert!(
        net.run_until(5_000, |net| net.online(0)),
        "the phone did not come online: {:?}",
        net.status(0)
    );
    net
}

fn answer(net: &Net, call: u64) -> Option<&Result<String, String>> {
    net.phones[0].answers.get(&call)
}

#[test]
fn pairs_once_and_answers_calls() {
    let mut net = paired();
    assert_eq!(net.phones[0].handshakes, 1);
    let call = net.rpc(0, r#"{"endpoint":"state"}"#);
    assert!(net.run_until(1_000, |net| answer(net, call).is_some()));
    assert_eq!(
        answer(&net, call).unwrap().as_deref(),
        Ok(r#"{"echo":{"endpoint":"state"}}"#)
    );
    assert_eq!(net.host.registry.list().len(), 1);
}

#[test]
fn a_call_made_before_the_link_is_up_goes_once_it_is() {
    let mut net = Net::new(GRACE);
    net.add_phone();
    let call = net.phones[0].core.rpc("bot", "1", 0, net.now);
    net.start();
    assert!(net.run_until(5_000, |net| answer(net, call).is_some()));
    assert_eq!(answer(&net, call).unwrap().as_deref(), Ok(r#"{"echo":1}"#));
    assert_eq!(net.host.served.len(), 1);
}

#[test]
fn a_cut_socket_resumes_without_a_handshake_and_keeps_the_call() {
    let mut net = paired();
    net.host.auto_answer = false;
    let call = net.rpc(0, r#""slow""#);
    net.run(200);
    assert_eq!(net.host.pending.len(), 1);
    for conn in net.conns_of(Side::Phone(0)) {
        net.cut(conn, true);
    }
    net.run(50);
    assert!(
        matches!(net.status(0), Some(LinkStatus::Reconnecting { .. })),
        "{:?}",
        net.status(0)
    );
    net.answer_pending();
    assert!(
        net.run_until(3_000, |net| answer(net, call).is_some()),
        "{:?}",
        net.status(0)
    );
    assert_eq!(
        answer(&net, call).unwrap().as_deref(),
        Ok(r#"{"echo":"slow"}"#)
    );
    assert_eq!(net.phones[0].handshakes, 1);
    assert_eq!(net.status(0), Some(&LinkStatus::Online { resumed: true }));
    assert_eq!(net.host.served.len(), 1, "the call ran once");
}

#[test]
fn events_sent_while_the_phone_is_away_arrive_in_order() {
    let mut net = paired();
    for conn in net.conns_of(Side::Phone(0)) {
        net.cut(conn, true);
    }
    for n in 0..300 {
        net.emit("stream", &n.to_string());
    }
    assert!(net.run_until(5_000, |net| net.phones[0].events.len() == 300));
    let got: Vec<String> = net.phones[0]
        .events
        .iter()
        .map(|(_, data)| data.clone())
        .collect();
    let want: Vec<String> = (0..300).map(|n: i32| n.to_string()).collect();
    assert_eq!(got, want);
    assert_eq!(net.phones[0].handshakes, 1);
}

#[test]
fn a_half_open_socket_is_found_and_resumed() {
    let mut net = paired();
    net.blackhole(Side::Phone(0));
    for n in 0..5 {
        net.emit("message", &n.to_string());
    }
    let call = net.rpc(0, "2");
    // Silence for 10 s, then a probe that times out after 10 s more.
    assert!(
        net.run_until(25_000, |net| answer(net, call).is_some()),
        "{:?}",
        net.status(0)
    );
    assert_eq!(answer(&net, call).unwrap().as_deref(), Ok(r#"{"echo":2}"#));
    assert_eq!(net.phones[0].events.len(), 5);
    assert_eq!(net.phones[0].handshakes, 1);
}

#[test]
fn a_network_change_redials_at_once() {
    let mut net = paired();
    net.blackhole(Side::Phone(0));
    let started = net.now;
    net.network_changed(0);
    let call = net.rpc(0, "3");
    assert!(net.run_until(2_000, |net| answer(net, call).is_some()));
    assert!(net.now - started < 1_000, "took {} ms", net.now - started);
    assert_eq!(net.phones[0].handshakes, 1);
}

#[test]
fn the_computer_dropping_off_shows_host_away_and_comes_back() {
    let mut net = paired();
    for conn in net.conns_of(Side::Host) {
        net.cut(conn, true);
    }
    net.relay_offline = true;
    assert!(
        net.run_until(2_000, |net| net.status(0) == Some(&LinkStatus::HostAway)),
        "{:?}",
        net.status(0)
    );
    let call = net.rpc(0, "4");
    net.relay_offline = false;
    assert!(
        net.run_until(5_000, |net| answer(net, call).is_some()),
        "{:?}",
        net.status(0)
    );
    assert_eq!(answer(&net, call).unwrap().as_deref(), Ok(r#"{"echo":4}"#));
    assert_eq!(net.phones[0].handshakes, 1);
}

#[test]
fn a_restarted_computer_means_a_new_session() {
    let mut net = paired();
    net.host.auto_answer = false;
    let call = net.rpc(0, "5");
    net.run(200);
    net.restart_host();
    assert!(
        net.run_until(5_000, |net| net.phones[0].handshakes == 2),
        "{:?}",
        net.status(0)
    );
    assert_eq!(
        answer(&net, call).unwrap().as_ref().unwrap_err(),
        "SESSION_RESET"
    );
    assert_eq!(net.status(0), Some(&LinkStatus::Online { resumed: false }));
}

#[test]
fn away_longer_than_the_grace_period_means_a_new_session() {
    let mut net = paired();
    net.relay_offline = true;
    for conn in net.conns_of(Side::Phone(0)) {
        net.cut(conn, true);
    }
    net.run(GRACE + 5_000);
    net.relay_offline = false;
    net.set_foreground(0, true);
    assert!(
        net.run_until(15_000, |net| net.phones[0].handshakes == 2),
        "{:?}",
        net.status(0)
    );
}

#[test]
fn background_and_foreground_never_strand_the_session() {
    let mut net = paired();
    net.relay_offline = true;
    for conn in net.conns_of(Side::Phone(0)) {
        net.cut(conn, true);
    }
    net.run(100);
    net.set_foreground(0, false);
    net.run(3_000);
    net.relay_offline = false;
    net.set_foreground(0, true);
    assert!(
        net.run_until(3_000, |net| net.online(0)),
        "{:?}",
        net.status(0)
    );
    assert_eq!(net.phones[0].handshakes, 1);
}

#[test]
fn a_removed_phone_is_rejected_for_good() {
    let mut net = paired();
    let device = net.phones[0].identity.device_id.clone();
    net.host.registry.revoke(&device);
    net.host.core.disconnect(&device, net.now);
    net.drain();
    assert!(net.run_until(1_000, |net| matches!(
        net.status(0),
        Some(LinkStatus::Rejected { .. })
    )));
    let call = net.rpc(0, "6");
    assert_eq!(
        answer(&net, call).unwrap().as_ref().unwrap_err(),
        "DEVICE_REVOKED"
    );
    net.run(30_000);
    assert!(net.conns_of(Side::Phone(0)).is_empty());
}

#[test]
fn a_wrong_pairing_code_is_rejected() {
    let mut net = Net::new(GRACE);
    net.add_phone();
    net.host.registry.close_pairing();
    net.start();
    assert!(
        net.run_until(5_000, |net| matches!(
            net.status(0),
            Some(LinkStatus::Rejected { .. })
        )),
        "{:?}",
        net.status(0)
    );
}

#[test]
fn many_cuts_during_a_stream_lose_nothing() {
    let mut net = paired();
    let mut sent = 0;
    for round in 0..20 {
        for _ in 0..50 {
            net.emit("stream", &sent.to_string());
            sent += 1;
        }
        net.run(30 + (round * 7) % 40);
        for conn in net.conns_of(if round % 3 == 0 {
            Side::Host
        } else {
            Side::Phone(0)
        }) {
            net.cut(conn, round % 2 == 0);
        }
        net.run(500);
    }
    assert!(
        net.run_until(120_000, |net| net.phones[0].events.len() == sent),
        "got {} of {sent}: {:?}",
        net.phones[0].events.len(),
        net.status(0)
    );
    let got: Vec<usize> = net.phones[0]
        .events
        .iter()
        .map(|(_, data)| data.parse().unwrap())
        .collect();
    assert_eq!(got, (0..sent).collect::<Vec<_>>());
    assert_eq!(net.phones[0].handshakes, 1);
}

#[test]
fn two_phones_do_not_disturb_each_other() {
    let mut net = Net::new(GRACE);
    net.add_phone();
    net.start();
    assert!(net.run_until(5_000, |net| net.online(0)));
    net.add_phone();
    net.phones[1].core.start(net.now);
    net.drain();
    assert!(
        net.run_until(5_000, |net| net.online(1)),
        "{:?}",
        net.status(1)
    );
    for conn in net.conns_of(Side::Phone(0)) {
        net.cut(conn, true);
    }
    let call = net.phones[1].core.rpc("bot", "7", 0, net.now);
    net.drain();
    assert!(net.run_until(1_000, |net| net.phones[1].answers.contains_key(&call)));
    assert!(net.run_until(3_000, |net| net.online(0)));
    assert_eq!((net.phones[0].handshakes, net.phones[1].handshakes), (1, 1));
}

#[test]
fn a_dead_socket_under_a_waiting_call_is_found_within_seconds() {
    let mut net = paired();
    net.blackhole(Side::Phone(0));
    let started = net.now;
    let call = net.rpc(0, "8");
    assert!(
        net.run_until(15_000, |net| answer(net, call).is_some()),
        "{:?}",
        net.status(0)
    );
    // 3 s of silence, a 5 s probe, a redial and an attach.
    assert!(net.now - started < 9_000, "took {} ms", net.now - started);
    assert_eq!(net.phones[0].handshakes, 1);
}

#[test]
fn a_large_reply_held_by_the_window_does_not_spin_the_computer() {
    let mut net = paired();
    let big = format!("\"{}\"", "x".repeat(3_000_000));
    let call = net.rpc(0, &big);
    let mut wakeups = 0;
    while answer(&net, call).is_none() && wakeups < 100_000 {
        let before = net.now;
        net.run(10);
        if net.host.core.next_deadline().is_some_and(|at| at <= before) {
            wakeups += 1;
        }
    }
    assert!(answer(&net, call).is_some());
    assert!(
        wakeups < 50,
        "the computer asked to wake in the past {wakeups} times"
    );
}
