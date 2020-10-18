import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:webfeed/webfeed.dart';
import 'package:uuid/uuid.dart';

import '../models/fireside_data.dart';
import '../models/service_api/searchpodcast.dart';
import '../storage/key_value_storage.dart';
import '../models/podcastlocal.dart';
import '../storage/sqflite_db.dart';

enum SubscribeState { none, start, subscribe, fetch, stop, exist, error }

final groupState = ChangeNotifierProvider((ref) => GroupList());

class GroupList extends ChangeNotifier {
  final List<PodcastGroup> _groups = [];
  List<PodcastGroup> get groups => _groups;
  final DBHelper _dbHelper = DBHelper();
  final KeyValueStorage _groupStorage = KeyValueStorage(groupsKey);
  bool _isLoading = false;
  bool get isLoading => _isLoading;

  @override
  void addListener(VoidCallback listener) {
    loadGroups().then((value) => super.addListener(listener));
  }

  /// Load groups from storage at start.
  Future<void> loadGroups() async {
    _isLoading = true;
    notifyListeners();
    _groupStorage.getGroups().then((loadgroups) async {
      _groups.addAll(loadgroups.map(PodcastGroup.fromEntity));
      for (var group in _groups) {
        await group.getPodcasts();
      }
      _isLoading = false;
      notifyListeners();
    });
  }

  /// Add new group.
  Future<void> addGroup(PodcastGroup podcastGroup) async {
    _isLoading = true;
    _groups.add(podcastGroup);
    await _saveGroup();
    _isLoading = false;
    notifyListeners();
  }

  /// Remove group.
  Future<void> delGroup(PodcastGroup podcastGroup) async {
    _isLoading = true;
    for (var podcast in podcastGroup.podcastList) {
      if (!_groups.first.podcastList.contains(podcast)) {
        _groups[0].podcastList.insert(0, podcast);
      }
    }
    await _saveGroup();
    _groups.remove(podcastGroup);
    await _groups[0].getPodcasts();
    _isLoading = false;
    notifyListeners();
  }

  Future<void> _saveGroup() async {
    await _groupStorage.saveGroup(_groups.map((it) => it.toEntity()).toList());
  }

  /// Current subsribe item from isolate.
  SubscribeItem _currentSubscribeItem =
      SubscribeItem('', '', subscribeState: SubscribeState.none);
  SubscribeItem get currentSubscribeItem => _currentSubscribeItem;

  Future<void> subscribePodcast(OnlinePodcast podcast) async {
    var rss = podcast.rss;
    var options = BaseOptions(
      connectTimeout: 30000,
      receiveTimeout: 90000,
    );
    final listColor = <String>[
      '388E3C',
      '1976D2',
      'D32F2F',
      '00796B',
    ];
    _setSubscribeState(podcast, SubscribeState.start);
    try {
      var response = await Dio(options).get(rss);
      RssFeed p;
      try {
        p = RssFeed.parse(response.data);
      } catch (e) {
        developer.log(e.toString(), name: 'Parse rss error');
        _setSubscribeState(podcast, SubscribeState.error);
      }

      var dir = await getApplicationDocumentsDirectory();
      var realUrl =
          response.redirects.isEmpty ? rss : response.realUri.toString();
      var checkUrl = await _dbHelper.checkPodcast(realUrl);
      if (checkUrl == '') {
        String imageUrl;
        img.Image thumbnail;
        try {
          var imageResponse = await Dio().get<List<int>>(p.itunes.image.href,
              options: Options(
                responseType: ResponseType.bytes,
                receiveTimeout: 90000,
              ));
          imageUrl = p.itunes.image.href;
          var image = img.decodeImage(imageResponse.data);
          thumbnail = img.copyResize(image, width: 300);
        } catch (e) {
          developer.log(e.toString(), name: 'Download image error');
          try {
            var imageResponse = await Dio().get<List<int>>(podcast.image,
                options: Options(
                  responseType: ResponseType.bytes,
                  receiveTimeout: 90000,
                ));
            imageUrl = podcast.image;
            var image = img.decodeImage(imageResponse.data);
            thumbnail = img.copyResize(image, width: 300);
          } catch (e) {
            developer.log(e.toString(), name: 'Download image error');
            try {
              var index = math.Random().nextInt(3);
              var imageResponse = await Dio().get<List<int>>(
                  "https://ui-avatars.com/api/?size=300&background="
                  "${listColor[index]}&color=fff&name=${podcast.title}&length=2&bold=true",
                  options: Options(responseType: ResponseType.bytes));
              imageUrl = "https://ui-avatars.com/api/?size=300&background="
                  "${listColor[index]}&color=fff&name=${podcast.title}&length=2&bold=true";
              thumbnail = img.decodeImage(imageResponse.data);
            } catch (e) {
              developer.log(e.toString(), name: 'Donwload image error');
              _setSubscribeState(podcast, SubscribeState.error);
              await Future.delayed(Duration(seconds: 2));
              _setSubscribeState(podcast, SubscribeState.stop);
            }
          }
        }
        var uuid = Uuid().v4();
        var imagePath = join(dir.path, '$uuid.png');
        File(imagePath)..writeAsBytesSync(img.encodePng(thumbnail));
        var primaryColor = await _getColor(thumbnail);
        var author = p.itunes.author ?? p.author ?? '';
        var provider = p.generator ?? '';
        var link = p.link ?? '';
        var podcastLocal = PodcastLocal(p.title, imageUrl, realUrl,
            primaryColor, author, uuid, imagePath, provider, link,
            description: p.description);

        _setSubscribeState(podcast, SubscribeState.subscribe);
        await _dbHelper.savePodcastLocal(podcastLocal);
        _subscribeNewPodcast(id: uuid);
        if (provider.contains('fireside')) {
          var data = FiresideData(uuid, link);
          try {
            await data.fatchData();
          } catch (e) {
            developer.log(e.toString(), name: 'Fatch fireside data error');
          }
        }
        await _dbHelper.savePodcastRss(p, uuid);
        _setSubscribeState(podcast, SubscribeState.fetch);
        await Future.delayed(Duration(seconds: 2));
        _setSubscribeState(podcast, SubscribeState.stop);
      } else {
        _setSubscribeState(podcast, SubscribeState.exist);
        await Future.delayed(Duration(seconds: 2));
        _setSubscribeState(podcast, SubscribeState.stop);
      }
    } catch (e) {
      developer.log(e.toString(), name: 'Download rss error');
      _setSubscribeState(podcast, SubscribeState.error);
      await Future.delayed(Duration(seconds: 2));
      _setSubscribeState(podcast, SubscribeState.stop);
    }
  }

  void _setSubscribeState(OnlinePodcast podcast, SubscribeState state) {
    _currentSubscribeItem =
        SubscribeItem(podcast.rss, podcast.title, subscribeState: state);
    notifyListeners();
  }

  /// Subscribe podcast from OPML.
  Future<bool> _subscribeNewPodcast(
      {String id, String groupName = 'Home'}) async {
    //List<String> groupNames = _groups.map((e) => e.name).toList();
    for (var group in _groups) {
      if (group.name == groupName) {
        if (group.podcastList.contains(id)) {
          return true;
        } else {
          _isLoading = true;
          notifyListeners();
          group.podcastList.insert(0, id);
          await _saveGroup();
          await group.getPodcasts();
          _isLoading = false;
          notifyListeners();
          return true;
        }
      }
    }
    _isLoading = true;
    notifyListeners();
    _groups.add(PodcastGroup(groupName, podcastList: [id]));
    //_groups.last.podcastList.insert(0, id);
    await _saveGroup();
    await _groups.last.getPodcasts();
    _isLoading = false;
    notifyListeners();
    return true;
  }

  Future<String> _getColor(img.Image image) async {
    var color = image.getPixel(150, 150);
    var g = (color >> 16) & 0xFF;
    var r = color & 0xFF;
    var b = (color >> 8) & 0xFF;
    return [r, g, b].toString();
  }
}

class GroupEntity {
  final String name;
  final String id;
  final String color;
  final List<String> podcastList;

  GroupEntity(this.name, this.id, this.color, this.podcastList);

  Map<String, Object> toJson() {
    return {'name': name, 'id': id, 'color': color, 'podcastList': podcastList};
  }

  static GroupEntity fromJson(Map<String, Object> json) {
    var list = List<String>.from(json['podcastList']);
    return GroupEntity(json['name'] as String, json['id'] as String,
        json['color'] as String, list);
  }
}

class PodcastGroup extends Equatable {
  /// Group name.
  final String name;

  final String id;

  /// Group theme color, not used.
  final String color;

  /// Id lists of podcasts in group.
  List<String> _podcastList;

  List<String> get podcastList => _podcastList;

  set podcastList(list) {
    _podcastList = list;
  }

  PodcastGroup(this.name,
      {this.color = '#000000', String id, List<String> podcastList})
      : id = id ?? Uuid().v4(),
        _podcastList = podcastList ?? [];

  Future<void> getPodcasts() async {
    var dbHelper = DBHelper();
    if (_podcastList != []) {
      try {
        _podcasts = await dbHelper.getPodcastLocal(_podcastList);
      } catch (e) {
        await Future.delayed(Duration(milliseconds: 200));
        try {
          _podcasts = await dbHelper.getPodcastLocal(_podcastList);
        } catch (e) {
          developer.log(e.toString());
        }
      }
    }
  }

  Color getColor() {
    if (color != '#000000') {
      var colorInt = int.parse('FF${color.toUpperCase()}', radix: 16);
      return Color(colorInt).withOpacity(1.0);
    } else {
      return Colors.blue[400];
    }
  }

  ///Podcast in group.
  List<PodcastLocal> _podcasts;
  List<PodcastLocal> get podcasts => _podcasts;

  ///Ordered podcast list.
  List<PodcastLocal> _orderedPodcasts;
  List<PodcastLocal> get orderedPodcasts => _orderedPodcasts;

  set orderedPodcasts(list) => _orderedPodcasts = list;

  GroupEntity toEntity() {
    return GroupEntity(name, id, color, podcastList);
  }

  static PodcastGroup fromEntity(GroupEntity entity) {
    return PodcastGroup(
      entity.name,
      id: entity.id,
      color: entity.color,
      podcastList: entity.podcastList,
    );
  }

  @override
  List<Object> get props => [id, name];
}

class SubscribeItem {
  ///Rss url.
  String url;

  ///Rss title.
  String title;

  /// Subscribe status.
  SubscribeState subscribeState;

  /// Podcast id.
  String id;

  ///Avatar image link.
  String imgUrl;

  ///Podcast group, default Home.
  String group;

  SubscribeItem(
    this.url,
    this.title, {
    this.subscribeState = SubscribeState.none,
    this.id = '',
    this.imgUrl = '',
    this.group = '',
  });
}