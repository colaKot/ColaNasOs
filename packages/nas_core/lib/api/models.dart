// AUTO-GENERATED. DO NOT EDIT.
// source: contracts/openapi.json
// regenerate: npm run gen:client

class BookLibraryItem {
  final String id;
  final String name;
  final String path;
  final String type;
  final int items;
  final int scanWhenStart;
  final int scanWhenChange;
  final int scanIntervalHours;
  final int createdAt;
  final int? lastScanAt;

  const BookLibraryItem({
    required this.id,
    required this.name,
    required this.path,
    required this.type,
    required this.items,
    required this.scanWhenStart,
    required this.scanWhenChange,
    required this.scanIntervalHours,
    required this.createdAt,
    required this.lastScanAt,
  });

  factory BookLibraryItem.fromJson(Map<String, dynamic> json) => BookLibraryItem(
        id: json['id'] as String,
        name: json['name'] as String,
        path: json['path'] as String,
        type: json['type'] as String,
        items: json['items'] as int,
        scanWhenStart: json['scanWhenStart'] as int,
        scanWhenChange: json['scanWhenChange'] as int,
        scanIntervalHours: json['scanIntervalHours'] as int,
        createdAt: json['createdAt'] as int,
        lastScanAt: json['lastScanAt'] as int?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'path': path,
        'type': type,
        'items': items,
        'scanWhenStart': scanWhenStart,
        'scanWhenChange': scanWhenChange,
        'scanIntervalHours': scanIntervalHours,
        'createdAt': createdAt,
        'lastScanAt': lastScanAt,
      };
}

class BookLibraryListResponse {
  final List<BookLibraryItem> items;

  const BookLibraryListResponse({
    required this.items,
  });

  factory BookLibraryListResponse.fromJson(Map<String, dynamic> json) => BookLibraryListResponse(
        items: (json['items'] as List<dynamic>).map((e) => BookLibraryItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class BookLibraryCreateBody {
  final String name;
  final String path;
  final dynamic type;

  const BookLibraryCreateBody({
    required this.name,
    required this.path,
    this.type,
  });

  factory BookLibraryCreateBody.fromJson(Map<String, dynamic> json) => BookLibraryCreateBody(
        name: json['name'] as String,
        path: json['path'] as String,
        type: json['type'] == null ? null : (json['type'] as dynamic),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'path': path,
        if (type != null) 'type': type!,
      };
}

class BookLibraryUpdateBody {
  final String id;
  final String? name;
  final dynamic type;
  final bool? scanWhenStart;
  final bool? scanWhenChange;
  final int? scanIntervalHours;

  const BookLibraryUpdateBody({
    required this.id,
    this.name,
    this.type,
    this.scanWhenStart,
    this.scanWhenChange,
    this.scanIntervalHours,
  });

  factory BookLibraryUpdateBody.fromJson(Map<String, dynamic> json) => BookLibraryUpdateBody(
        id: json['id'] as String,
        name: json['name'] == null ? null : json['name'] as String,
        type: json['type'] == null ? null : (json['type'] as dynamic),
        scanWhenStart: json['scanWhenStart'] == null ? null : json['scanWhenStart'] as bool,
        scanWhenChange: json['scanWhenChange'] == null ? null : json['scanWhenChange'] as bool,
        scanIntervalHours: json['scanIntervalHours'] == null ? null : json['scanIntervalHours'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (name != null) 'name': name!,
        if (type != null) 'type': type!,
        if (scanWhenStart != null) 'scanWhenStart': scanWhenStart!,
        if (scanWhenChange != null) 'scanWhenChange': scanWhenChange!,
        if (scanIntervalHours != null) 'scanIntervalHours': scanIntervalHours!,
      };
}

class BookLibraryRemoveBody {
  final String id;

  const BookLibraryRemoveBody({
    required this.id,
  });

  factory BookLibraryRemoveBody.fromJson(Map<String, dynamic> json) => BookLibraryRemoveBody(
        id: json['id'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
      };
}

class BookScanBody {
  final String? libraryId;
  final int? limit;
  final bool? prune;

  const BookScanBody({
    this.libraryId,
    this.limit,
    this.prune,
  });

  factory BookScanBody.fromJson(Map<String, dynamic> json) => BookScanBody(
        libraryId: json['libraryId'] == null ? null : json['libraryId'] as String,
        limit: json['limit'] == null ? null : json['limit'] as int,
        prune: json['prune'] == null ? null : json['prune'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (libraryId != null) 'libraryId': libraryId!,
        if (limit != null) 'limit': limit!,
        if (prune != null) 'prune': prune!,
      };
}

class BookScanResponse {
  final int libraries;
  final int books;
  final int added;
  final int updated;
  final int skipped;
  final int parsed;
  final int? missing;
  final int? pruned;

  const BookScanResponse({
    required this.libraries,
    required this.books,
    required this.added,
    required this.updated,
    required this.skipped,
    required this.parsed,
    this.missing,
    this.pruned,
  });

  factory BookScanResponse.fromJson(Map<String, dynamic> json) => BookScanResponse(
        libraries: json['libraries'] as int,
        books: json['books'] as int,
        added: json['added'] as int,
        updated: json['updated'] as int,
        skipped: json['skipped'] as int,
        parsed: json['parsed'] as int,
        missing: json['missing'] == null ? null : json['missing'] as int,
        pruned: json['pruned'] == null ? null : json['pruned'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'libraries': libraries,
        'books': books,
        'added': added,
        'updated': updated,
        'skipped': skipped,
        'parsed': parsed,
        if (missing != null) 'missing': missing!,
        if (pruned != null) 'pruned': pruned!,
      };
}

class BookItem {
  final String id;
  final String libraryId;
  final String path;
  final String type;
  final String title;
  final String? author;
  final String? language;
  final String? publisher;
  final String format;
  final int? pageCount;
  final bool hasCover;
  final int size;
  final bool favorite;
  final int? progressPercent;
  final String? collection;
  final int? collectionIndex;
  final bool archived;

  const BookItem({
    required this.id,
    required this.libraryId,
    required this.path,
    required this.type,
    required this.title,
    required this.author,
    required this.language,
    required this.publisher,
    required this.format,
    required this.pageCount,
    required this.hasCover,
    required this.size,
    required this.favorite,
    required this.progressPercent,
    required this.collection,
    required this.collectionIndex,
    required this.archived,
  });

  factory BookItem.fromJson(Map<String, dynamic> json) => BookItem(
        id: json['id'] as String,
        libraryId: json['libraryId'] as String,
        path: json['path'] as String,
        type: json['type'] as String,
        title: json['title'] as String,
        author: json['author'] as String?,
        language: json['language'] as String?,
        publisher: json['publisher'] as String?,
        format: json['format'] as String,
        pageCount: json['pageCount'] as int?,
        hasCover: json['hasCover'] as bool,
        size: json['size'] as int,
        favorite: json['favorite'] as bool,
        progressPercent: json['progressPercent'] as int?,
        collection: json['collection'] as String?,
        collectionIndex: json['collectionIndex'] as int?,
        archived: json['archived'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'libraryId': libraryId,
        'path': path,
        'type': type,
        'title': title,
        'author': author,
        'language': language,
        'publisher': publisher,
        'format': format,
        'pageCount': pageCount,
        'hasCover': hasCover,
        'size': size,
        'favorite': favorite,
        'progressPercent': progressPercent,
        'collection': collection,
        'collectionIndex': collectionIndex,
        'archived': archived,
      };
}

class BookListResponse {
  final List<BookItem> items;
  final String? nextCursor;

  const BookListResponse({
    required this.items,
    required this.nextCursor,
  });

  factory BookListResponse.fromJson(Map<String, dynamic> json) => BookListResponse(
        items: (json['items'] as List<dynamic>).map((e) => BookItem.fromJson(e as Map<String, dynamic>)).toList(),
        nextCursor: json['nextCursor'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
        'nextCursor': nextCursor,
      };
}

class BookFileUrlResponse {
  final String url;
  final int expiresInSec;

  const BookFileUrlResponse({
    required this.url,
    required this.expiresInSec,
  });

  factory BookFileUrlResponse.fromJson(Map<String, dynamic> json) => BookFileUrlResponse(
        url: json['url'] as String,
        expiresInSec: json['expiresInSec'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'expiresInSec': expiresInSec,
      };
}

class BookStatsResponse {
  final int libraries;
  final int books;
  final int bookCount;
  final int comicCount;
  final int favorites;

  const BookStatsResponse({
    required this.libraries,
    required this.books,
    required this.bookCount,
    required this.comicCount,
    required this.favorites,
  });

  factory BookStatsResponse.fromJson(Map<String, dynamic> json) => BookStatsResponse(
        libraries: json['libraries'] as int,
        books: json['books'] as int,
        bookCount: json['bookCount'] as int,
        comicCount: json['comicCount'] as int,
        favorites: json['favorites'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'libraries': libraries,
        'books': books,
        'bookCount': bookCount,
        'comicCount': comicCount,
        'favorites': favorites,
      };
}

class BookFavoriteBody {
  final String id;

  const BookFavoriteBody({
    required this.id,
  });

  factory BookFavoriteBody.fromJson(Map<String, dynamic> json) => BookFavoriteBody(
        id: json['id'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
      };
}

class BookProgressBody {
  final String id;
  final String position;
  final int percent;

  const BookProgressBody({
    required this.id,
    required this.position,
    required this.percent,
  });

  factory BookProgressBody.fromJson(Map<String, dynamic> json) => BookProgressBody(
        id: json['id'] as String,
        position: json['position'] as String,
        percent: json['percent'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'position': position,
        'percent': percent,
      };
}

class BookProgress {
  final String bookId;
  final String position;
  final int percent;
  final int updatedAt;

  const BookProgress({
    required this.bookId,
    required this.position,
    required this.percent,
    required this.updatedAt,
  });

  factory BookProgress.fromJson(Map<String, dynamic> json) => BookProgress(
        bookId: json['bookId'] as String,
        position: json['position'] as String,
        percent: json['percent'] as int,
        updatedAt: json['updatedAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'bookId': bookId,
        'position': position,
        'percent': percent,
        'updatedAt': updatedAt,
      };
}

class BookTocPage {
  final int index;
  final String title;

  const BookTocPage({
    required this.index,
    required this.title,
  });

  factory BookTocPage.fromJson(Map<String, dynamic> json) => BookTocPage(
        index: json['index'] as int,
        title: json['title'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'index': index,
        'title': title,
      };
}

class BookTocResponse {
  final String kind;
  final int total;
  final List<Map<String, dynamic>> pages;

  const BookTocResponse({
    required this.kind,
    required this.total,
    required this.pages,
  });

  factory BookTocResponse.fromJson(Map<String, dynamic> json) => BookTocResponse(
        kind: json['kind'] as String,
        total: json['total'] as int,
        pages: (json['pages'] as List<dynamic>).cast<Map<String, dynamic>>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
        'total': total,
        'pages': pages,
      };
}

class BookPageResponse {
  final String kind;
  final int index;
  final String title;
  final String? text;
  final bool? truncated;
  final String? mime;
  final String? data;

  const BookPageResponse({
    required this.kind,
    required this.index,
    required this.title,
    this.text,
    this.truncated,
    this.mime,
    this.data,
  });

  factory BookPageResponse.fromJson(Map<String, dynamic> json) => BookPageResponse(
        kind: json['kind'] as String,
        index: json['index'] as int,
        title: json['title'] as String,
        text: json['text'] == null ? null : json['text'] as String,
        truncated: json['truncated'] == null ? null : json['truncated'] as bool,
        mime: json['mime'] == null ? null : json['mime'] as String,
        data: json['data'] == null ? null : json['data'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
        'index': index,
        'title': title,
        if (text != null) 'text': text!,
        if (truncated != null) 'truncated': truncated!,
        if (mime != null) 'mime': mime!,
        if (data != null) 'data': data!,
      };
}

class BookOkResponse {
  final bool ok;

  const BookOkResponse({
    required this.ok,
  });

  factory BookOkResponse.fromJson(Map<String, dynamic> json) => BookOkResponse(
        ok: json['ok'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
      };
}

class BookCollectionItem {
  final String name;
  final int books;
  final String? coverId;

  const BookCollectionItem({
    required this.name,
    required this.books,
    required this.coverId,
  });

  factory BookCollectionItem.fromJson(Map<String, dynamic> json) => BookCollectionItem(
        name: json['name'] as String,
        books: json['books'] as int,
        coverId: json['coverId'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'books': books,
        'coverId': coverId,
      };
}

class BookCollectionsResponse {
  final List<BookCollectionItem> items;
  final String? nextCursor;

  const BookCollectionsResponse({
    required this.items,
    required this.nextCursor,
  });

  factory BookCollectionsResponse.fromJson(Map<String, dynamic> json) => BookCollectionsResponse(
        items: (json['items'] as List<dynamic>).map((e) => BookCollectionItem.fromJson(e as Map<String, dynamic>)).toList(),
        nextCursor: json['nextCursor'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
        'nextCursor': nextCursor,
      };
}

class BookCollectionBody {
  final String id;
  final String? name;
  final int? index;

  const BookCollectionBody({
    required this.id,
    this.name,
    this.index,
  });

  factory BookCollectionBody.fromJson(Map<String, dynamic> json) => BookCollectionBody(
        id: json['id'] as String,
        name: json['name'] == null ? null : json['name'] as String?,
        index: json['index'] == null ? null : json['index'] as int?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (name != null) 'name': name!,
        if (index != null) 'index': index!,
      };
}

class BookArchiveBody {
  final String id;
  final bool? archived;

  const BookArchiveBody({
    required this.id,
    this.archived,
  });

  factory BookArchiveBody.fromJson(Map<String, dynamic> json) => BookArchiveBody(
        id: json['id'] as String,
        archived: json['archived'] == null ? null : json['archived'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (archived != null) 'archived': archived!,
      };
}

class BookListItem {
  final String id;
  final String name;
  final int books;
  final int createdAt;

  const BookListItem({
    required this.id,
    required this.name,
    required this.books,
    required this.createdAt,
  });

  factory BookListItem.fromJson(Map<String, dynamic> json) => BookListItem(
        id: json['id'] as String,
        name: json['name'] as String,
        books: json['books'] as int,
        createdAt: json['createdAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'books': books,
        'createdAt': createdAt,
      };
}

class BookListsResponse {
  final List<BookListItem> items;

  const BookListsResponse({
    required this.items,
  });

  factory BookListsResponse.fromJson(Map<String, dynamic> json) => BookListsResponse(
        items: (json['items'] as List<dynamic>).map((e) => BookListItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class BookListCreateBody {
  final String name;

  const BookListCreateBody({
    required this.name,
  });

  factory BookListCreateBody.fromJson(Map<String, dynamic> json) => BookListCreateBody(
        name: json['name'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
      };
}

class BookListRemoveBody {
  final String id;

  const BookListRemoveBody({
    required this.id,
  });

  factory BookListRemoveBody.fromJson(Map<String, dynamic> json) => BookListRemoveBody(
        id: json['id'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
      };
}

class BookListRenameBody {
  final String id;
  final String name;

  const BookListRenameBody({
    required this.id,
    required this.name,
  });

  factory BookListRenameBody.fromJson(Map<String, dynamic> json) => BookListRenameBody(
        id: json['id'] as String,
        name: json['name'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
      };
}

class BookListRefBody {
  final String listId;
  final String bookId;

  const BookListRefBody({
    required this.listId,
    required this.bookId,
  });

  factory BookListRefBody.fromJson(Map<String, dynamic> json) => BookListRefBody(
        listId: json['listId'] as String,
        bookId: json['bookId'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'listId': listId,
        'bookId': bookId,
      };
}

class BookListItemsResponse {
  final List<BookItem> items;

  const BookListItemsResponse({
    required this.items,
  });

  factory BookListItemsResponse.fromJson(Map<String, dynamic> json) => BookListItemsResponse(
        items: (json['items'] as List<dynamic>).map((e) => BookItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class BookCacheStatsResponse {
  final int files;
  final int bytes;

  const BookCacheStatsResponse({
    required this.files,
    required this.bytes,
  });

  factory BookCacheStatsResponse.fromJson(Map<String, dynamic> json) => BookCacheStatsResponse(
        files: json['files'] as int,
        bytes: json['bytes'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'files': files,
        'bytes': bytes,
      };
}

class BookCacheClearResponse {
  final int files;
  final int bytes;

  const BookCacheClearResponse({
    required this.files,
    required this.bytes,
  });

  factory BookCacheClearResponse.fromJson(Map<String, dynamic> json) => BookCacheClearResponse(
        files: json['files'] as int,
        bytes: json['bytes'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'files': files,
        'bytes': bytes,
      };
}

class BookUserCollection {
  final String id;
  final String name;
  final List<String> paths;
  final int books;
  final String? coverId;
  final int createdAt;
  final int updatedAt;

  const BookUserCollection({
    required this.id,
    required this.name,
    required this.paths,
    required this.books,
    required this.coverId,
    required this.createdAt,
    required this.updatedAt,
  });

  factory BookUserCollection.fromJson(Map<String, dynamic> json) => BookUserCollection(
        id: json['id'] as String,
        name: json['name'] as String,
        paths: (json['paths'] as List<dynamic>).cast<String>(),
        books: json['books'] as int,
        coverId: json['coverId'] as String?,
        createdAt: json['createdAt'] as int,
        updatedAt: json['updatedAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'paths': paths,
        'books': books,
        'coverId': coverId,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };
}

class BookUserCollectionListResponse {
  final List<BookUserCollection> items;

  const BookUserCollectionListResponse({
    required this.items,
  });

  factory BookUserCollectionListResponse.fromJson(Map<String, dynamic> json) => BookUserCollectionListResponse(
        items: (json['items'] as List<dynamic>).map((e) => BookUserCollection.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class BookUserCollectionBody {
  final String name;
  final List<String> paths;

  const BookUserCollectionBody({
    required this.name,
    required this.paths,
  });

  factory BookUserCollectionBody.fromJson(Map<String, dynamic> json) => BookUserCollectionBody(
        name: json['name'] as String,
        paths: (json['paths'] as List<dynamic>).cast<String>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'paths': paths,
      };
}

class BookUserCollectionUpdateBody {
  final String id;
  final String? name;
  final List<String>? paths;

  const BookUserCollectionUpdateBody({
    required this.id,
    this.name,
    this.paths,
  });

  factory BookUserCollectionUpdateBody.fromJson(Map<String, dynamic> json) => BookUserCollectionUpdateBody(
        id: json['id'] as String,
        name: json['name'] == null ? null : json['name'] as String,
        paths: json['paths'] == null ? null : (json['paths'] as List<dynamic>).cast<String>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (name != null) 'name': name!,
        if (paths != null) 'paths': paths!,
      };
}

class BookErrorResponse {
  final String error;
  final String? message;
  final String? code;
  final String? traceId;
  final Map<String, dynamic>? details;

  const BookErrorResponse({
    required this.error,
    this.message,
    this.code,
    this.traceId,
    this.details,
  });

  factory BookErrorResponse.fromJson(Map<String, dynamic> json) => BookErrorResponse(
        error: json['error'] as String,
        message: json['message'] == null ? null : json['message'] as String,
        code: json['code'] == null ? null : json['code'] as String,
        traceId: json['traceId'] == null ? null : json['traceId'] as String,
        details: json['details'] == null ? null : json['details'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'error': error,
        if (message != null) 'message': message!,
        if (code != null) 'code': code!,
        if (traceId != null) 'traceId': traceId!,
        if (details != null) 'details': details!,
      };
}

class BookFulltextReindexBody {

  const BookFulltextReindexBody();

  factory BookFulltextReindexBody.fromJson(Map<String, dynamic> json) => BookFulltextReindexBody(
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
      };
}

class BookFulltextHit {
  final String bookId;
  final String title;
  final String? author;
  final String snippet;

  const BookFulltextHit({
    required this.bookId,
    required this.title,
    required this.author,
    required this.snippet,
  });

  factory BookFulltextHit.fromJson(Map<String, dynamic> json) => BookFulltextHit(
        bookId: json['bookId'] as String,
        title: json['title'] as String,
        author: json['author'] as String?,
        snippet: json['snippet'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'bookId': bookId,
        'title': title,
        'author': author,
        'snippet': snippet,
      };
}

class BookFulltextResponse {
  final List<BookFulltextHit> items;
  final int total;

  const BookFulltextResponse({
    required this.items,
    required this.total,
  });

  factory BookFulltextResponse.fromJson(Map<String, dynamic> json) => BookFulltextResponse(
        items: (json['items'] as List<dynamic>).map((e) => BookFulltextHit.fromJson(e as Map<String, dynamic>)).toList(),
        total: json['total'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
        'total': total,
      };
}

class BookFulltextReindexResponse {
  final int indexed;
  final int skipped;

  const BookFulltextReindexResponse({
    required this.indexed,
    required this.skipped,
  });

  factory BookFulltextReindexResponse.fromJson(Map<String, dynamic> json) => BookFulltextReindexResponse(
        indexed: json['indexed'] as int,
        skipped: json['skipped'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'indexed': indexed,
        'skipped': skipped,
      };
}

class BookFulltextError {
  final String error;
  final String? message;
  final String? code;
  final String? traceId;
  final Map<String, dynamic>? details;

  const BookFulltextError({
    required this.error,
    this.message,
    this.code,
    this.traceId,
    this.details,
  });

  factory BookFulltextError.fromJson(Map<String, dynamic> json) => BookFulltextError(
        error: json['error'] as String,
        message: json['message'] == null ? null : json['message'] as String,
        code: json['code'] == null ? null : json['code'] as String,
        traceId: json['traceId'] == null ? null : json['traceId'] as String,
        details: json['details'] == null ? null : json['details'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'error': error,
        if (message != null) 'message': message!,
        if (code != null) 'code': code!,
        if (traceId != null) 'traceId': traceId!,
        if (details != null) 'details': details!,
      };
}

class DiscoverScrapeBody {
  final String? libraryId;

  const DiscoverScrapeBody({
    this.libraryId,
  });

  factory DiscoverScrapeBody.fromJson(Map<String, dynamic> json) => DiscoverScrapeBody(
        libraryId: json['libraryId'] == null ? null : json['libraryId'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (libraryId != null) 'libraryId': libraryId!,
      };
}

class DiscoverScrapeResponse {
  final int scanned;
  final int scraped;
  final int skipped;

  const DiscoverScrapeResponse({
    required this.scanned,
    required this.scraped,
    required this.skipped,
  });

  factory DiscoverScrapeResponse.fromJson(Map<String, dynamic> json) => DiscoverScrapeResponse(
        scanned: json['scanned'] as int,
        scraped: json['scraped'] as int,
        skipped: json['skipped'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'scanned': scanned,
        'scraped': scraped,
        'skipped': skipped,
      };
}

class DiscoverMetaItem {
  final String itemId;
  final String title;
  final String? plot;
  final int? year;
  final String? genre;
  final double? rating;
  final int updatedAt;

  const DiscoverMetaItem({
    required this.itemId,
    required this.title,
    required this.plot,
    required this.year,
    required this.genre,
    required this.rating,
    required this.updatedAt,
  });

  factory DiscoverMetaItem.fromJson(Map<String, dynamic> json) => DiscoverMetaItem(
        itemId: json['itemId'] as String,
        title: json['title'] as String,
        plot: json['plot'] as String?,
        year: json['year'] as int?,
        genre: json['genre'] as String?,
        rating: (json['rating'] as num?)?.toDouble(),
        updatedAt: json['updatedAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'itemId': itemId,
        'title': title,
        'plot': plot,
        'year': year,
        'genre': genre,
        'rating': rating,
        'updatedAt': updatedAt,
      };
}

class DiscoverMetaList {
  final List<DiscoverMetaItem> items;

  const DiscoverMetaList({
    required this.items,
  });

  factory DiscoverMetaList.fromJson(Map<String, dynamic> json) => DiscoverMetaList(
        items: (json['items'] as List<dynamic>).map((e) => DiscoverMetaItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class DiscoverError {
  final String error;
  final String? message;
  final String? code;
  final String? traceId;
  final Map<String, dynamic>? details;

  const DiscoverError({
    required this.error,
    this.message,
    this.code,
    this.traceId,
    this.details,
  });

  factory DiscoverError.fromJson(Map<String, dynamic> json) => DiscoverError(
        error: json['error'] as String,
        message: json['message'] == null ? null : json['message'] as String,
        code: json['code'] == null ? null : json['code'] as String,
        traceId: json['traceId'] == null ? null : json['traceId'] as String,
        details: json['details'] == null ? null : json['details'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'error': error,
        if (message != null) 'message': message!,
        if (code != null) 'code': code!,
        if (traceId != null) 'traceId': traceId!,
        if (details != null) 'details': details!,
      };
}

class DiscoverSettings {
  final bool apiKeyConfigured;
  final String apiKey;
  final String baseUrl;
  final String language;
  final String imageBase;

  const DiscoverSettings({
    required this.apiKeyConfigured,
    required this.apiKey,
    required this.baseUrl,
    required this.language,
    required this.imageBase,
  });

  factory DiscoverSettings.fromJson(Map<String, dynamic> json) => DiscoverSettings(
        apiKeyConfigured: json['apiKeyConfigured'] as bool,
        apiKey: json['apiKey'] as String,
        baseUrl: json['baseUrl'] as String,
        language: json['language'] as String,
        imageBase: json['imageBase'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'apiKeyConfigured': apiKeyConfigured,
        'apiKey': apiKey,
        'baseUrl': baseUrl,
        'language': language,
        'imageBase': imageBase,
      };
}

class DiscoverSettingsBody {
  final String? apiKey;
  final String? baseUrl;
  final String? language;
  final String? imageBase;

  const DiscoverSettingsBody({
    this.apiKey,
    this.baseUrl,
    this.language,
    this.imageBase,
  });

  factory DiscoverSettingsBody.fromJson(Map<String, dynamic> json) => DiscoverSettingsBody(
        apiKey: json['apiKey'] == null ? null : json['apiKey'] as String,
        baseUrl: json['baseUrl'] == null ? null : json['baseUrl'] as String,
        language: json['language'] == null ? null : json['language'] as String,
        imageBase: json['imageBase'] == null ? null : json['imageBase'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (apiKey != null) 'apiKey': apiKey!,
        if (baseUrl != null) 'baseUrl': baseUrl!,
        if (language != null) 'language': language!,
        if (imageBase != null) 'imageBase': imageBase!,
      };
}

class DiscoverMediaCard {
  final int id;
  final String mediaType;
  final String title;
  final String originalTitle;
  final String overview;
  final String? posterPath;
  final String? backdropPath;
  final int? year;
  final double? rating;
  final bool? owned;
  final bool? favorited;

  const DiscoverMediaCard({
    required this.id,
    required this.mediaType,
    required this.title,
    required this.originalTitle,
    required this.overview,
    required this.posterPath,
    required this.backdropPath,
    required this.year,
    required this.rating,
    this.owned,
    this.favorited,
  });

  factory DiscoverMediaCard.fromJson(Map<String, dynamic> json) => DiscoverMediaCard(
        id: json['id'] as int,
        mediaType: json['mediaType'] as String,
        title: json['title'] as String,
        originalTitle: json['originalTitle'] as String,
        overview: json['overview'] as String,
        posterPath: json['posterPath'] as String?,
        backdropPath: json['backdropPath'] as String?,
        year: json['year'] as int?,
        rating: (json['rating'] as num?)?.toDouble(),
        owned: json['owned'] == null ? null : json['owned'] as bool,
        favorited: json['favorited'] == null ? null : json['favorited'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'mediaType': mediaType,
        'title': title,
        'originalTitle': originalTitle,
        'overview': overview,
        'posterPath': posterPath,
        'backdropPath': backdropPath,
        'year': year,
        'rating': rating,
        if (owned != null) 'owned': owned!,
        if (favorited != null) 'favorited': favorited!,
      };
}

class DiscoverCatalogResponse {
  final List<DiscoverMediaCard> items;
  final int page;
  final int totalPages;
  final bool degraded;
  final String reason;
  final bool? stale;
  final int? snapshotAt;

  const DiscoverCatalogResponse({
    required this.items,
    required this.page,
    required this.totalPages,
    required this.degraded,
    required this.reason,
    this.stale,
    this.snapshotAt,
  });

  factory DiscoverCatalogResponse.fromJson(Map<String, dynamic> json) => DiscoverCatalogResponse(
        items: (json['items'] as List<dynamic>).map((e) => DiscoverMediaCard.fromJson(e as Map<String, dynamic>)).toList(),
        page: json['page'] as int,
        totalPages: json['totalPages'] as int,
        degraded: json['degraded'] as bool,
        reason: json['reason'] as String,
        stale: json['stale'] == null ? null : json['stale'] as bool,
        snapshotAt: json['snapshotAt'] == null ? null : json['snapshotAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
        'page': page,
        'totalPages': totalPages,
        'degraded': degraded,
        'reason': reason,
        if (stale != null) 'stale': stale!,
        if (snapshotAt != null) 'snapshotAt': snapshotAt!,
      };
}

class DiscoverCatalogSnapshotItem {
  final String catalogType;
  final String key;
  final int itemCount;
  final int snapshotAt;
  final int ageSec;
  final bool fresh;

  const DiscoverCatalogSnapshotItem({
    required this.catalogType,
    required this.key,
    required this.itemCount,
    required this.snapshotAt,
    required this.ageSec,
    required this.fresh,
  });

  factory DiscoverCatalogSnapshotItem.fromJson(Map<String, dynamic> json) => DiscoverCatalogSnapshotItem(
        catalogType: json['catalogType'] as String,
        key: json['key'] as String,
        itemCount: json['itemCount'] as int,
        snapshotAt: json['snapshotAt'] as int,
        ageSec: json['ageSec'] as int,
        fresh: json['fresh'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'catalogType': catalogType,
        'key': key,
        'itemCount': itemCount,
        'snapshotAt': snapshotAt,
        'ageSec': ageSec,
        'fresh': fresh,
      };
}

class DiscoverCatalogSnapshotList {
  final List<DiscoverCatalogSnapshotItem> items;

  const DiscoverCatalogSnapshotList({
    required this.items,
  });

  factory DiscoverCatalogSnapshotList.fromJson(Map<String, dynamic> json) => DiscoverCatalogSnapshotList(
        items: (json['items'] as List<dynamic>).map((e) => DiscoverCatalogSnapshotItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class DiscoverCatalogPruneResponse {
  final int pruned;

  const DiscoverCatalogPruneResponse({
    required this.pruned,
  });

  factory DiscoverCatalogPruneResponse.fromJson(Map<String, dynamic> json) => DiscoverCatalogPruneResponse(
        pruned: json['pruned'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'pruned': pruned,
      };
}

class DiscoverDetailResponse {
  final int id;
  final String mediaType;
  final String title;
  final String originalTitle;
  final String overview;
  final String? posterPath;
  final String? backdropPath;
  final int? year;
  final int? runtime;
  final double? rating;
  final List<String> genres;
  final List<String> cast;
  final List<Map<String, dynamic>> seasons;
  final bool degraded;
  final String reason;

  const DiscoverDetailResponse({
    required this.id,
    required this.mediaType,
    required this.title,
    required this.originalTitle,
    required this.overview,
    required this.posterPath,
    required this.backdropPath,
    required this.year,
    required this.runtime,
    required this.rating,
    required this.genres,
    required this.cast,
    required this.seasons,
    required this.degraded,
    required this.reason,
  });

  factory DiscoverDetailResponse.fromJson(Map<String, dynamic> json) => DiscoverDetailResponse(
        id: json['id'] as int,
        mediaType: json['mediaType'] as String,
        title: json['title'] as String,
        originalTitle: json['originalTitle'] as String,
        overview: json['overview'] as String,
        posterPath: json['posterPath'] as String?,
        backdropPath: json['backdropPath'] as String?,
        year: json['year'] as int?,
        runtime: json['runtime'] as int?,
        rating: (json['rating'] as num?)?.toDouble(),
        genres: (json['genres'] as List<dynamic>).cast<String>(),
        cast: (json['cast'] as List<dynamic>).cast<String>(),
        seasons: (json['seasons'] as List<dynamic>).cast<Map<String, dynamic>>(),
        degraded: json['degraded'] as bool,
        reason: json['reason'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'mediaType': mediaType,
        'title': title,
        'originalTitle': originalTitle,
        'overview': overview,
        'posterPath': posterPath,
        'backdropPath': backdropPath,
        'year': year,
        'runtime': runtime,
        'rating': rating,
        'genres': genres,
        'cast': cast,
        'seasons': seasons,
        'degraded': degraded,
        'reason': reason,
      };
}

class DiscoverFavoriteBody {
  final int id;
  final String mediaType;
  final bool favorite;

  const DiscoverFavoriteBody({
    required this.id,
    required this.mediaType,
    required this.favorite,
  });

  factory DiscoverFavoriteBody.fromJson(Map<String, dynamic> json) => DiscoverFavoriteBody(
        id: json['id'] as int,
        mediaType: json['mediaType'] as String,
        favorite: json['favorite'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'mediaType': mediaType,
        'favorite': favorite,
      };
}

class DiscoverFavoriteResponse {
  final bool favorite;

  const DiscoverFavoriteResponse({
    required this.favorite,
  });

  factory DiscoverFavoriteResponse.fromJson(Map<String, dynamic> json) => DiscoverFavoriteResponse(
        favorite: json['favorite'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'favorite': favorite,
      };
}

class DiscoverFavoriteListResponse {
  final List<Map<String, dynamic>> items;

  const DiscoverFavoriteListResponse({
    required this.items,
  });

  factory DiscoverFavoriteListResponse.fromJson(Map<String, dynamic> json) => DiscoverFavoriteListResponse(
        items: (json['items'] as List<dynamic>).cast<Map<String, dynamic>>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items,
      };
}

class DiscoverApiError {
  final String error;
  final String? message;
  final String? code;
  final String? traceId;
  final Map<String, dynamic>? details;

  const DiscoverApiError({
    required this.error,
    this.message,
    this.code,
    this.traceId,
    this.details,
  });

  factory DiscoverApiError.fromJson(Map<String, dynamic> json) => DiscoverApiError(
        error: json['error'] as String,
        message: json['message'] == null ? null : json['message'] as String,
        code: json['code'] == null ? null : json['code'] as String,
        traceId: json['traceId'] == null ? null : json['traceId'] as String,
        details: json['details'] == null ? null : json['details'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'error': error,
        if (message != null) 'message': message!,
        if (code != null) 'code': code!,
        if (traceId != null) 'traceId': traceId!,
        if (details != null) 'details': details!,
      };
}

class FilesListItem {
  final String name;
  final bool dir;

  const FilesListItem({
    required this.name,
    required this.dir,
  });

  factory FilesListItem.fromJson(Map<String, dynamic> json) => FilesListItem(
        name: json['name'] as String,
        dir: json['dir'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'dir': dir,
      };
}

class FilesListResponse {
  final String path;
  final List<FilesListItem> items;
  final String? nextCursor;

  const FilesListResponse({
    required this.path,
    required this.items,
    required this.nextCursor,
  });

  factory FilesListResponse.fromJson(Map<String, dynamic> json) => FilesListResponse(
        path: json['path'] as String,
        items: (json['items'] as List<dynamic>).map((e) => FilesListItem.fromJson(e as Map<String, dynamic>)).toList(),
        nextCursor: json['nextCursor'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'items': items.map((e) => e.toJson()).toList(),
        'nextCursor': nextCursor,
      };
}

class FilesRootItem {
  final String path;
  final String label;
  final dynamic kind;

  const FilesRootItem({
    required this.path,
    required this.label,
    required this.kind,
  });

  factory FilesRootItem.fromJson(Map<String, dynamic> json) => FilesRootItem(
        path: json['path'] as String,
        label: json['label'] as String,
        kind: (json['kind'] as dynamic),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'label': label,
        'kind': kind,
      };
}

class FilesRootsResponse {
  final String home;
  final List<FilesRootItem> roots;

  const FilesRootsResponse({
    required this.home,
    required this.roots,
  });

  factory FilesRootsResponse.fromJson(Map<String, dynamic> json) => FilesRootsResponse(
        home: json['home'] as String,
        roots: (json['roots'] as List<dynamic>).map((e) => FilesRootItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'home': home,
        'roots': roots.map((e) => e.toJson()).toList(),
      };
}

class FilesCheckBody {
  final String path;
  final int? size;
  final String? hash;

  const FilesCheckBody({
    required this.path,
    this.size,
    this.hash,
  });

  factory FilesCheckBody.fromJson(Map<String, dynamic> json) => FilesCheckBody(
        path: json['path'] as String,
        size: json['size'] == null ? null : json['size'] as int,
        hash: json['hash'] == null ? null : json['hash'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        if (size != null) 'size': size!,
        if (hash != null) 'hash': hash!,
      };
}

class FilesCheckResponse {
  final String path;
  final bool exists;
  final String uploadId;
  final List<int> uploaded;
  final int chunkSize;

  const FilesCheckResponse({
    required this.path,
    required this.exists,
    required this.uploadId,
    required this.uploaded,
    required this.chunkSize,
  });

  factory FilesCheckResponse.fromJson(Map<String, dynamic> json) => FilesCheckResponse(
        path: json['path'] as String,
        exists: json['exists'] as bool,
        uploadId: json['uploadId'] as String,
        uploaded: (json['uploaded'] as List<dynamic>).cast<int>(),
        chunkSize: json['chunkSize'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'exists': exists,
        'uploadId': uploadId,
        'uploaded': uploaded,
        'chunkSize': chunkSize,
      };
}

class FilesChunkResponse {
  final bool ok;
  final String uploadId;
  final int index;
  final int size;

  const FilesChunkResponse({
    required this.ok,
    required this.uploadId,
    required this.index,
    required this.size,
  });

  factory FilesChunkResponse.fromJson(Map<String, dynamic> json) => FilesChunkResponse(
        ok: json['ok'] as bool,
        uploadId: json['uploadId'] as String,
        index: json['index'] as int,
        size: json['size'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        'uploadId': uploadId,
        'index': index,
        'size': size,
      };
}

class FilesMergeBody {
  final String path;
  final int total;
  final int? size;
  final String? hash;
  final double? mtimeMs;

  const FilesMergeBody({
    required this.path,
    required this.total,
    this.size,
    this.hash,
    this.mtimeMs,
  });

  factory FilesMergeBody.fromJson(Map<String, dynamic> json) => FilesMergeBody(
        path: json['path'] as String,
        total: json['total'] as int,
        size: json['size'] == null ? null : json['size'] as int,
        hash: json['hash'] == null ? null : json['hash'] as String,
        mtimeMs: json['mtimeMs'] == null ? null : (json['mtimeMs'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'total': total,
        if (size != null) 'size': size!,
        if (hash != null) 'hash': hash!,
        if (mtimeMs != null) 'mtimeMs': mtimeMs!,
      };
}

class FilesMergeResponse {
  final bool ok;
  final String path;
  final int size;
  final bool skipped;

  const FilesMergeResponse({
    required this.ok,
    required this.path,
    required this.size,
    required this.skipped,
  });

  factory FilesMergeResponse.fromJson(Map<String, dynamic> json) => FilesMergeResponse(
        ok: json['ok'] as bool,
        path: json['path'] as String,
        size: json['size'] as int,
        skipped: json['skipped'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        'path': path,
        'size': size,
        'skipped': skipped,
      };
}

class FilesErrorResponse {
  final String error;
  final String? message;
  final String? code;
  final String? traceId;
  final Map<String, dynamic>? details;

  const FilesErrorResponse({
    required this.error,
    this.message,
    this.code,
    this.traceId,
    this.details,
  });

  factory FilesErrorResponse.fromJson(Map<String, dynamic> json) => FilesErrorResponse(
        error: json['error'] as String,
        message: json['message'] == null ? null : json['message'] as String,
        code: json['code'] == null ? null : json['code'] as String,
        traceId: json['traceId'] == null ? null : json['traceId'] as String,
        details: json['details'] == null ? null : json['details'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'error': error,
        if (message != null) 'message': message!,
        if (code != null) 'code': code!,
        if (traceId != null) 'traceId': traceId!,
        if (details != null) 'details': details!,
      };
}

class FilesIndexStartResponse {
  final String taskId;
  final bool reused;

  const FilesIndexStartResponse({
    required this.taskId,
    required this.reused,
  });

  factory FilesIndexStartResponse.fromJson(Map<String, dynamic> json) => FilesIndexStartResponse(
        taskId: json['taskId'] as String,
        reused: json['reused'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'taskId': taskId,
        'reused': reused,
      };
}

class FilesIndexStatusResponse {
  final String root;
  final int indexed;
  final int lastSeq;
  final int? updatedAt;
  final bool running;
  final int batches;
  final double maxTxMs;

  const FilesIndexStatusResponse({
    required this.root,
    required this.indexed,
    required this.lastSeq,
    required this.updatedAt,
    required this.running,
    required this.batches,
    required this.maxTxMs,
  });

  factory FilesIndexStatusResponse.fromJson(Map<String, dynamic> json) => FilesIndexStatusResponse(
        root: json['root'] as String,
        indexed: json['indexed'] as int,
        lastSeq: json['lastSeq'] as int,
        updatedAt: json['updatedAt'] as int?,
        running: json['running'] as bool,
        batches: json['batches'] as int,
        maxTxMs: (json['maxTxMs'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'root': root,
        'indexed': indexed,
        'lastSeq': lastSeq,
        'updatedAt': updatedAt,
        'running': running,
        'batches': batches,
        'maxTxMs': maxTxMs,
      };
}

class FilesSearchResponse {
  final List<Map<String, dynamic>> items;

  const FilesSearchResponse({
    required this.items,
  });

  factory FilesSearchResponse.fromJson(Map<String, dynamic> json) => FilesSearchResponse(
        items: (json['items'] as List<dynamic>).cast<Map<String, dynamic>>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items,
      };
}

class FilesOpPathBody {
  final String path;

  const FilesOpPathBody({
    required this.path,
  });

  factory FilesOpPathBody.fromJson(Map<String, dynamic> json) => FilesOpPathBody(
        path: json['path'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
      };
}

class FilesMkdirResponse {
  final String path;

  const FilesMkdirResponse({
    required this.path,
  });

  factory FilesMkdirResponse.fromJson(Map<String, dynamic> json) => FilesMkdirResponse(
        path: json['path'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
      };
}

class FilesRenameBody {
  final String path;
  final String name;

  const FilesRenameBody({
    required this.path,
    required this.name,
  });

  factory FilesRenameBody.fromJson(Map<String, dynamic> json) => FilesRenameBody(
        path: json['path'] as String,
        name: json['name'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'name': name,
      };
}

class FilesRenameResponse {
  final String path;
  final String from;

  const FilesRenameResponse({
    required this.path,
    required this.from,
  });

  factory FilesRenameResponse.fromJson(Map<String, dynamic> json) => FilesRenameResponse(
        path: json['path'] as String,
        from: json['from'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'from': from,
      };
}

class FilesMoveBody {
  final List<String> paths;
  final String to;
  final bool? copy;

  const FilesMoveBody({
    required this.paths,
    required this.to,
    this.copy,
  });

  factory FilesMoveBody.fromJson(Map<String, dynamic> json) => FilesMoveBody(
        paths: (json['paths'] as List<dynamic>).cast<String>(),
        to: json['to'] as String,
        copy: json['copy'] == null ? null : json['copy'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'paths': paths,
        'to': to,
        if (copy != null) 'copy': copy!,
      };
}

class FilesDeleteBody {
  final List<String> paths;
  final bool? permanent;

  const FilesDeleteBody({
    required this.paths,
    this.permanent,
  });

  factory FilesDeleteBody.fromJson(Map<String, dynamic> json) => FilesDeleteBody(
        paths: (json['paths'] as List<dynamic>).cast<String>(),
        permanent: json['permanent'] == null ? null : json['permanent'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'paths': paths,
        if (permanent != null) 'permanent': permanent!,
      };
}

class FilesOpFailure {
  final String path;
  final String error;

  const FilesOpFailure({
    required this.path,
    required this.error,
  });

  factory FilesOpFailure.fromJson(Map<String, dynamic> json) => FilesOpFailure(
        path: json['path'] as String,
        error: json['error'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'error': error,
      };
}

class FilesOpResult {
  final List<String> done;
  final List<FilesOpFailure> failed;
  final String? trashedTo;

  const FilesOpResult({
    required this.done,
    required this.failed,
    this.trashedTo,
  });

  factory FilesOpResult.fromJson(Map<String, dynamic> json) => FilesOpResult(
        done: (json['done'] as List<dynamic>).cast<String>(),
        failed: (json['failed'] as List<dynamic>).map((e) => FilesOpFailure.fromJson(e as Map<String, dynamic>)).toList(),
        trashedTo: json['trashedTo'] == null ? null : json['trashedTo'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'done': done,
        'failed': failed.map((e) => e.toJson()).toList(),
        if (trashedTo != null) 'trashedTo': trashedTo!,
      };
}

class FilesTrashItem {
  final String name;
  final bool dir;
  final int size;

  const FilesTrashItem({
    required this.name,
    required this.dir,
    required this.size,
  });

  factory FilesTrashItem.fromJson(Map<String, dynamic> json) => FilesTrashItem(
        name: json['name'] as String,
        dir: json['dir'] as bool,
        size: json['size'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'dir': dir,
        'size': size,
      };
}

class FilesTrashBatch {
  final String batch;
  final List<FilesTrashItem> items;

  const FilesTrashBatch({
    required this.batch,
    required this.items,
  });

  factory FilesTrashBatch.fromJson(Map<String, dynamic> json) => FilesTrashBatch(
        batch: json['batch'] as String,
        items: (json['items'] as List<dynamic>).map((e) => FilesTrashItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'batch': batch,
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class FilesTrashListResponse {
  final List<FilesTrashBatch> batches;

  const FilesTrashListResponse({
    required this.batches,
  });

  factory FilesTrashListResponse.fromJson(Map<String, dynamic> json) => FilesTrashListResponse(
        batches: (json['batches'] as List<dynamic>).map((e) => FilesTrashBatch.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'batches': batches.map((e) => e.toJson()).toList(),
      };
}

class FilesTrashRestoreBody {
  final String batch;
  final List<String> paths;

  const FilesTrashRestoreBody({
    required this.batch,
    required this.paths,
  });

  factory FilesTrashRestoreBody.fromJson(Map<String, dynamic> json) => FilesTrashRestoreBody(
        batch: json['batch'] as String,
        paths: (json['paths'] as List<dynamic>).cast<String>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'batch': batch,
        'paths': paths,
      };
}

class FilesTrashEmptyBody {
  final String? batch;

  const FilesTrashEmptyBody({
    this.batch,
  });

  factory FilesTrashEmptyBody.fromJson(Map<String, dynamic> json) => FilesTrashEmptyBody(
        batch: json['batch'] == null ? null : json['batch'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (batch != null) 'batch': batch!,
      };
}

class FilesTrashEmptyResponse {
  final int removed;

  const FilesTrashEmptyResponse({
    required this.removed,
  });

  factory FilesTrashEmptyResponse.fromJson(Map<String, dynamic> json) => FilesTrashEmptyResponse(
        removed: json['removed'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'removed': removed,
      };
}

class FilesOpLogItem {
  final String id;
  final String uid;
  final String username;
  final String action;
  final String status;
  final String path;
  final String detail;
  final String ip;
  final int createdAt;

  const FilesOpLogItem({
    required this.id,
    required this.uid,
    required this.username,
    required this.action,
    required this.status,
    required this.path,
    required this.detail,
    required this.ip,
    required this.createdAt,
  });

  factory FilesOpLogItem.fromJson(Map<String, dynamic> json) => FilesOpLogItem(
        id: json['id'] as String,
        uid: json['uid'] as String,
        username: json['username'] as String,
        action: json['action'] as String,
        status: json['status'] as String,
        path: json['path'] as String,
        detail: json['detail'] as String,
        ip: json['ip'] as String,
        createdAt: json['createdAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'uid': uid,
        'username': username,
        'action': action,
        'status': status,
        'path': path,
        'detail': detail,
        'ip': ip,
        'createdAt': createdAt,
      };
}

class FilesOpLogListResponse {
  final List<FilesOpLogItem> items;
  final int total;
  final int limit;
  final int offset;

  const FilesOpLogListResponse({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  factory FilesOpLogListResponse.fromJson(Map<String, dynamic> json) => FilesOpLogListResponse(
        items: (json['items'] as List<dynamic>).map((e) => FilesOpLogItem.fromJson(e as Map<String, dynamic>)).toList(),
        total: json['total'] as int,
        limit: json['limit'] as int,
        offset: json['offset'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
        'total': total,
        'limit': limit,
        'offset': offset,
      };
}

class MediaToolThumbnailsBody {
  final String source;
  final String? target;
  final int? size;

  const MediaToolThumbnailsBody({
    required this.source,
    this.target,
    this.size,
  });

  factory MediaToolThumbnailsBody.fromJson(Map<String, dynamic> json) => MediaToolThumbnailsBody(
        source: json['source'] as String,
        target: json['target'] == null ? null : json['target'] as String,
        size: json['size'] == null ? null : json['size'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'source': source,
        if (target != null) 'target': target!,
        if (size != null) 'size': size!,
      };
}

class MediaToolTranscodeBody {
  final String source;
  final String target;
  final dynamic preset;

  const MediaToolTranscodeBody({
    required this.source,
    required this.target,
    this.preset,
  });

  factory MediaToolTranscodeBody.fromJson(Map<String, dynamic> json) => MediaToolTranscodeBody(
        source: json['source'] as String,
        target: json['target'] as String,
        preset: json['preset'] == null ? null : (json['preset'] as dynamic),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'source': source,
        'target': target,
        if (preset != null) 'preset': preset!,
      };
}

class MediaToolJobCreated {
  final String id;

  const MediaToolJobCreated({
    required this.id,
  });

  factory MediaToolJobCreated.fromJson(Map<String, dynamic> json) => MediaToolJobCreated(
        id: json['id'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
      };
}

class MediaToolJobItem {
  final String id;
  final dynamic kind;
  final String source;
  final String target;
  final dynamic status;
  final int total;
  final int done;
  final int failed;
  final String? error;
  final int createdAt;
  final int updatedAt;

  const MediaToolJobItem({
    required this.id,
    required this.kind,
    required this.source,
    required this.target,
    required this.status,
    required this.total,
    required this.done,
    required this.failed,
    required this.error,
    required this.createdAt,
    required this.updatedAt,
  });

  factory MediaToolJobItem.fromJson(Map<String, dynamic> json) => MediaToolJobItem(
        id: json['id'] as String,
        kind: (json['kind'] as dynamic),
        source: json['source'] as String,
        target: json['target'] as String,
        status: (json['status'] as dynamic),
        total: json['total'] as int,
        done: json['done'] as int,
        failed: json['failed'] as int,
        error: json['error'] as String?,
        createdAt: json['createdAt'] as int,
        updatedAt: json['updatedAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'kind': kind,
        'source': source,
        'target': target,
        'status': status,
        'total': total,
        'done': done,
        'failed': failed,
        'error': error,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };
}

class MediaToolJobListResponse {
  final List<MediaToolJobItem> items;

  const MediaToolJobListResponse({
    required this.items,
  });

  factory MediaToolJobListResponse.fromJson(Map<String, dynamic> json) => MediaToolJobListResponse(
        items: (json['items'] as List<dynamic>).map((e) => MediaToolJobItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class MediaToolIdBody {
  final String id;

  const MediaToolIdBody({
    required this.id,
  });

  factory MediaToolIdBody.fromJson(Map<String, dynamic> json) => MediaToolIdBody(
        id: json['id'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
      };
}

class MediaToolOkResponse {
  final bool ok;

  const MediaToolOkResponse({
    required this.ok,
  });

  factory MediaToolOkResponse.fromJson(Map<String, dynamic> json) => MediaToolOkResponse(
        ok: json['ok'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
      };
}

class MediaToolErrorResponse {
  final String error;
  final String? message;
  final String? code;
  final String? traceId;
  final Map<String, dynamic>? details;

  const MediaToolErrorResponse({
    required this.error,
    this.message,
    this.code,
    this.traceId,
    this.details,
  });

  factory MediaToolErrorResponse.fromJson(Map<String, dynamic> json) => MediaToolErrorResponse(
        error: json['error'] as String,
        message: json['message'] == null ? null : json['message'] as String,
        code: json['code'] == null ? null : json['code'] as String,
        traceId: json['traceId'] == null ? null : json['traceId'] as String,
        details: json['details'] == null ? null : json['details'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'error': error,
        if (message != null) 'message': message!,
        if (code != null) 'code': code!,
        if (traceId != null) 'traceId': traceId!,
        if (details != null) 'details': details!,
      };
}

class MediaToolTaskItem {
  final String id;
  final String uid;
  final String kind;
  final String source;
  final String target;
  final Map<String, dynamic> config;
  final String status;
  final int total;
  final int done;
  final int processed;
  final int skipped;
  final int nonMedia;
  final int failed;
  final int inBytes;
  final int outBytes;
  final double progress;
  final String? lastError;
  final int? startAt;
  final int? endAt;
  final int createdAt;
  final int updatedAt;

  const MediaToolTaskItem({
    required this.id,
    required this.uid,
    required this.kind,
    required this.source,
    required this.target,
    required this.config,
    required this.status,
    required this.total,
    required this.done,
    required this.processed,
    required this.skipped,
    required this.nonMedia,
    required this.failed,
    required this.inBytes,
    required this.outBytes,
    required this.progress,
    required this.lastError,
    required this.startAt,
    required this.endAt,
    required this.createdAt,
    required this.updatedAt,
  });

  factory MediaToolTaskItem.fromJson(Map<String, dynamic> json) => MediaToolTaskItem(
        id: json['id'] as String,
        uid: json['uid'] as String,
        kind: json['kind'] as String,
        source: json['source'] as String,
        target: json['target'] as String,
        config: json['config'] as Map<String, dynamic>,
        status: json['status'] as String,
        total: json['total'] as int,
        done: json['done'] as int,
        processed: json['processed'] as int,
        skipped: json['skipped'] as int,
        nonMedia: json['nonMedia'] as int,
        failed: json['failed'] as int,
        inBytes: json['inBytes'] as int,
        outBytes: json['outBytes'] as int,
        progress: (json['progress'] as num).toDouble(),
        lastError: json['lastError'] as String?,
        startAt: json['startAt'] as int?,
        endAt: json['endAt'] as int?,
        createdAt: json['createdAt'] as int,
        updatedAt: json['updatedAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'uid': uid,
        'kind': kind,
        'source': source,
        'target': target,
        'config': config,
        'status': status,
        'total': total,
        'done': done,
        'processed': processed,
        'skipped': skipped,
        'nonMedia': nonMedia,
        'failed': failed,
        'inBytes': inBytes,
        'outBytes': outBytes,
        'progress': progress,
        'lastError': lastError,
        'startAt': startAt,
        'endAt': endAt,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };
}

class MediaToolTaskListResponse {
  final List<MediaToolTaskItem> items;

  const MediaToolTaskListResponse({
    required this.items,
  });

  factory MediaToolTaskListResponse.fromJson(Map<String, dynamic> json) => MediaToolTaskListResponse(
        items: (json['items'] as List<dynamic>).map((e) => MediaToolTaskItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class MediaToolTaskUpsertBody {
  final String? id;
  final dynamic kind;
  final String source;
  final String target;
  final Map<String, dynamic>? config;

  const MediaToolTaskUpsertBody({
    this.id,
    required this.kind,
    required this.source,
    required this.target,
    this.config,
  });

  factory MediaToolTaskUpsertBody.fromJson(Map<String, dynamic> json) => MediaToolTaskUpsertBody(
        id: json['id'] == null ? null : json['id'] as String,
        kind: (json['kind'] as dynamic),
        source: json['source'] as String,
        target: json['target'] as String,
        config: json['config'] == null ? null : json['config'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (id != null) 'id': id!,
        'kind': kind,
        'source': source,
        'target': target,
        if (config != null) 'config': config!,
      };
}

class MediaToolTaskIdBody {
  final String id;

  const MediaToolTaskIdBody({
    required this.id,
  });

  factory MediaToolTaskIdBody.fromJson(Map<String, dynamic> json) => MediaToolTaskIdBody(
        id: json['id'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
      };
}

class MediaToolTaskOkResponse {
  final bool ok;

  const MediaToolTaskOkResponse({
    required this.ok,
  });

  factory MediaToolTaskOkResponse.fromJson(Map<String, dynamic> json) => MediaToolTaskOkResponse(
        ok: json['ok'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
      };
}

class MountItem {
  final String id;
  final String name;
  final String kind;
  final String baseUrl;
  final String username;
  final String rootPath;
  final bool readOnly;
  final String status;
  final String? lastError;
  final int? lastCheckAt;
  final int createdAt;

  const MountItem({
    required this.id,
    required this.name,
    required this.kind,
    required this.baseUrl,
    required this.username,
    required this.rootPath,
    required this.readOnly,
    required this.status,
    required this.lastError,
    required this.lastCheckAt,
    required this.createdAt,
  });

  factory MountItem.fromJson(Map<String, dynamic> json) => MountItem(
        id: json['id'] as String,
        name: json['name'] as String,
        kind: json['kind'] as String,
        baseUrl: json['baseUrl'] as String,
        username: json['username'] as String,
        rootPath: json['rootPath'] as String,
        readOnly: json['readOnly'] as bool,
        status: json['status'] as String,
        lastError: json['lastError'] as String?,
        lastCheckAt: json['lastCheckAt'] as int?,
        createdAt: json['createdAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'kind': kind,
        'baseUrl': baseUrl,
        'username': username,
        'rootPath': rootPath,
        'readOnly': readOnly,
        'status': status,
        'lastError': lastError,
        'lastCheckAt': lastCheckAt,
        'createdAt': createdAt,
      };
}

class MountListResponse {
  final List<MountItem> items;

  const MountListResponse({
    required this.items,
  });

  factory MountListResponse.fromJson(Map<String, dynamic> json) => MountListResponse(
        items: (json['items'] as List<dynamic>).map((e) => MountItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class MountCreateBody {
  final String name;
  final String kind;
  final String baseUrl;
  final String? username;
  final String? password;
  final String? rootPath;
  final bool? readOnly;

  const MountCreateBody({
    required this.name,
    required this.kind,
    required this.baseUrl,
    this.username,
    this.password,
    this.rootPath,
    this.readOnly,
  });

  factory MountCreateBody.fromJson(Map<String, dynamic> json) => MountCreateBody(
        name: json['name'] as String,
        kind: json['kind'] as String,
        baseUrl: json['baseUrl'] as String,
        username: json['username'] == null ? null : json['username'] as String,
        password: json['password'] == null ? null : json['password'] as String,
        rootPath: json['rootPath'] == null ? null : json['rootPath'] as String,
        readOnly: json['readOnly'] == null ? null : json['readOnly'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'kind': kind,
        'baseUrl': baseUrl,
        if (username != null) 'username': username!,
        if (password != null) 'password': password!,
        if (rootPath != null) 'rootPath': rootPath!,
        if (readOnly != null) 'readOnly': readOnly!,
      };
}

class MountRemoveBody {
  final String id;

  const MountRemoveBody({
    required this.id,
  });

  factory MountRemoveBody.fromJson(Map<String, dynamic> json) => MountRemoveBody(
        id: json['id'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
      };
}

class MountTestBody {
  final String id;

  const MountTestBody({
    required this.id,
  });

  factory MountTestBody.fromJson(Map<String, dynamic> json) => MountTestBody(
        id: json['id'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
      };
}

class MountEntry {
  final String name;
  final String path;
  final bool dir;
  final int size;
  final int? mtime;

  const MountEntry({
    required this.name,
    required this.path,
    required this.dir,
    required this.size,
    required this.mtime,
  });

  factory MountEntry.fromJson(Map<String, dynamic> json) => MountEntry(
        name: json['name'] as String,
        path: json['path'] as String,
        dir: json['dir'] as bool,
        size: json['size'] as int,
        mtime: json['mtime'] as int?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'path': path,
        'dir': dir,
        'size': size,
        'mtime': mtime,
      };
}

class MountBrowseResponse {
  final String path;
  final List<MountEntry> items;

  const MountBrowseResponse({
    required this.path,
    required this.items,
  });

  factory MountBrowseResponse.fromJson(Map<String, dynamic> json) => MountBrowseResponse(
        path: json['path'] as String,
        items: (json['items'] as List<dynamic>).map((e) => MountEntry.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class MountDownloadUrlResponse {
  final String url;
  final int expiresInSec;

  const MountDownloadUrlResponse({
    required this.url,
    required this.expiresInSec,
  });

  factory MountDownloadUrlResponse.fromJson(Map<String, dynamic> json) => MountDownloadUrlResponse(
        url: json['url'] as String,
        expiresInSec: json['expiresInSec'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'expiresInSec': expiresInSec,
      };
}

class MountPathBody {
  final String id;
  final String path;

  const MountPathBody({
    required this.id,
    required this.path,
  });

  factory MountPathBody.fromJson(Map<String, dynamic> json) => MountPathBody(
        id: json['id'] as String,
        path: json['path'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'path': path,
      };
}

class MountTargetResponse {
  final MountItem mount;
  final String path;

  const MountTargetResponse({
    required this.mount,
    required this.path,
  });

  factory MountTargetResponse.fromJson(Map<String, dynamic> json) => MountTargetResponse(
        mount: MountItem.fromJson(json['mount'] as Map<String, dynamic>),
        path: json['path'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mount': mount.toJson(),
        'path': path,
      };
}

class MountOkResponse {
  final bool ok;

  const MountOkResponse({
    required this.ok,
  });

  factory MountOkResponse.fromJson(Map<String, dynamic> json) => MountOkResponse(
        ok: json['ok'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
      };
}

class MountErrorResponse {
  final String error;
  final String? message;
  final String? code;
  final String? traceId;
  final Map<String, dynamic>? details;

  const MountErrorResponse({
    required this.error,
    this.message,
    this.code,
    this.traceId,
    this.details,
  });

  factory MountErrorResponse.fromJson(Map<String, dynamic> json) => MountErrorResponse(
        error: json['error'] as String,
        message: json['message'] == null ? null : json['message'] as String,
        code: json['code'] == null ? null : json['code'] as String,
        traceId: json['traceId'] == null ? null : json['traceId'] as String,
        details: json['details'] == null ? null : json['details'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'error': error,
        if (message != null) 'message': message!,
        if (code != null) 'code': code!,
        if (traceId != null) 'traceId': traceId!,
        if (details != null) 'details': details!,
      };
}

class MusicLibraryItem {
  final String id;
  final String name;
  final String path;
  final int items;
  final int createdAt;
  final int? lastScanAt;

  const MusicLibraryItem({
    required this.id,
    required this.name,
    required this.path,
    required this.items,
    required this.createdAt,
    required this.lastScanAt,
  });

  factory MusicLibraryItem.fromJson(Map<String, dynamic> json) => MusicLibraryItem(
        id: json['id'] as String,
        name: json['name'] as String,
        path: json['path'] as String,
        items: json['items'] as int,
        createdAt: json['createdAt'] as int,
        lastScanAt: json['lastScanAt'] as int?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'path': path,
        'items': items,
        'createdAt': createdAt,
        'lastScanAt': lastScanAt,
      };
}

class MusicLibraryListResponse {
  final List<MusicLibraryItem> items;

  const MusicLibraryListResponse({
    required this.items,
  });

  factory MusicLibraryListResponse.fromJson(Map<String, dynamic> json) => MusicLibraryListResponse(
        items: (json['items'] as List<dynamic>).map((e) => MusicLibraryItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class MusicLibraryCreateBody {
  final String name;
  final String path;

  const MusicLibraryCreateBody({
    required this.name,
    required this.path,
  });

  factory MusicLibraryCreateBody.fromJson(Map<String, dynamic> json) => MusicLibraryCreateBody(
        name: json['name'] as String,
        path: json['path'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'path': path,
      };
}

class MusicLibraryRemoveBody {
  final String id;

  const MusicLibraryRemoveBody({
    required this.id,
  });

  factory MusicLibraryRemoveBody.fromJson(Map<String, dynamic> json) => MusicLibraryRemoveBody(
        id: json['id'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
      };
}

class MusicCacheStatsResponse {
  final int files;
  final int bytes;

  const MusicCacheStatsResponse({
    required this.files,
    required this.bytes,
  });

  factory MusicCacheStatsResponse.fromJson(Map<String, dynamic> json) => MusicCacheStatsResponse(
        files: json['files'] as int,
        bytes: json['bytes'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'files': files,
        'bytes': bytes,
      };
}

class MusicCacheClearResponse {
  final int removed;
  final int bytes;

  const MusicCacheClearResponse({
    required this.removed,
    required this.bytes,
  });

  factory MusicCacheClearResponse.fromJson(Map<String, dynamic> json) => MusicCacheClearResponse(
        removed: json['removed'] as int,
        bytes: json['bytes'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'removed': removed,
        'bytes': bytes,
      };
}

class MusicScanBody {
  final String? libraryId;
  final int? limit;
  final bool? prune;

  const MusicScanBody({
    this.libraryId,
    this.limit,
    this.prune,
  });

  factory MusicScanBody.fromJson(Map<String, dynamic> json) => MusicScanBody(
        libraryId: json['libraryId'] == null ? null : json['libraryId'] as String,
        limit: json['limit'] == null ? null : json['limit'] as int,
        prune: json['prune'] == null ? null : json['prune'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (libraryId != null) 'libraryId': libraryId!,
        if (limit != null) 'limit': limit!,
        if (prune != null) 'prune': prune!,
      };
}

class MusicScanResponse {
  final int libraries;
  final int tracks;
  final int added;
  final int updated;
  final int skipped;
  final int probed;
  final int? missing;
  final int? pruned;

  const MusicScanResponse({
    required this.libraries,
    required this.tracks,
    required this.added,
    required this.updated,
    required this.skipped,
    required this.probed,
    this.missing,
    this.pruned,
  });

  factory MusicScanResponse.fromJson(Map<String, dynamic> json) => MusicScanResponse(
        libraries: json['libraries'] as int,
        tracks: json['tracks'] as int,
        added: json['added'] as int,
        updated: json['updated'] as int,
        skipped: json['skipped'] as int,
        probed: json['probed'] as int,
        missing: json['missing'] == null ? null : json['missing'] as int,
        pruned: json['pruned'] == null ? null : json['pruned'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'libraries': libraries,
        'tracks': tracks,
        'added': added,
        'updated': updated,
        'skipped': skipped,
        'probed': probed,
        if (missing != null) 'missing': missing!,
        if (pruned != null) 'pruned': pruned!,
      };
}

class MusicTrack {
  final String id;
  final String libraryId;
  final String path;
  final String title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final String? genre;
  final int? trackNo;
  final int? year;
  final int? durationMs;
  final int? bitrate;
  final int? sampleRate;
  final String? channels;
  final String? codec;
  final bool hasCover;
  final int size;

  const MusicTrack({
    required this.id,
    required this.libraryId,
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.albumArtist,
    required this.genre,
    required this.trackNo,
    required this.year,
    required this.durationMs,
    required this.bitrate,
    required this.sampleRate,
    required this.channels,
    required this.codec,
    required this.hasCover,
    required this.size,
  });

  factory MusicTrack.fromJson(Map<String, dynamic> json) => MusicTrack(
        id: json['id'] as String,
        libraryId: json['libraryId'] as String,
        path: json['path'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String?,
        album: json['album'] as String?,
        albumArtist: json['albumArtist'] as String?,
        genre: json['genre'] as String?,
        trackNo: json['trackNo'] as int?,
        year: json['year'] as int?,
        durationMs: json['durationMs'] as int?,
        bitrate: json['bitrate'] as int?,
        sampleRate: json['sampleRate'] as int?,
        channels: json['channels'] as String?,
        codec: json['codec'] as String?,
        hasCover: json['hasCover'] as bool,
        size: json['size'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'libraryId': libraryId,
        'path': path,
        'title': title,
        'artist': artist,
        'album': album,
        'albumArtist': albumArtist,
        'genre': genre,
        'trackNo': trackNo,
        'year': year,
        'durationMs': durationMs,
        'bitrate': bitrate,
        'sampleRate': sampleRate,
        'channels': channels,
        'codec': codec,
        'hasCover': hasCover,
        'size': size,
      };
}

class MusicListResponse {
  final List<MusicTrack> items;
  final String? nextCursor;

  const MusicListResponse({
    required this.items,
    required this.nextCursor,
  });

  factory MusicListResponse.fromJson(Map<String, dynamic> json) => MusicListResponse(
        items: (json['items'] as List<dynamic>).map((e) => MusicTrack.fromJson(e as Map<String, dynamic>)).toList(),
        nextCursor: json['nextCursor'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
        'nextCursor': nextCursor,
      };
}

class MusicAlbum {
  final String name;
  final String? artist;
  final int? year;
  final int tracks;
  final int durationMs;
  final String? coverTrackId;

  const MusicAlbum({
    required this.name,
    required this.artist,
    required this.year,
    required this.tracks,
    required this.durationMs,
    required this.coverTrackId,
  });

  factory MusicAlbum.fromJson(Map<String, dynamic> json) => MusicAlbum(
        name: json['name'] as String,
        artist: json['artist'] as String?,
        year: json['year'] as int?,
        tracks: json['tracks'] as int,
        durationMs: json['durationMs'] as int,
        coverTrackId: json['coverTrackId'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'artist': artist,
        'year': year,
        'tracks': tracks,
        'durationMs': durationMs,
        'coverTrackId': coverTrackId,
      };
}

class MusicAlbumListResponse {
  final List<MusicAlbum> items;

  const MusicAlbumListResponse({
    required this.items,
  });

  factory MusicAlbumListResponse.fromJson(Map<String, dynamic> json) => MusicAlbumListResponse(
        items: (json['items'] as List<dynamic>).map((e) => MusicAlbum.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class MusicArtist {
  final String name;
  final int tracks;
  final int albums;
  final int durationMs;
  final String? coverTrackId;

  const MusicArtist({
    required this.name,
    required this.tracks,
    required this.albums,
    required this.durationMs,
    required this.coverTrackId,
  });

  factory MusicArtist.fromJson(Map<String, dynamic> json) => MusicArtist(
        name: json['name'] as String,
        tracks: json['tracks'] as int,
        albums: json['albums'] as int,
        durationMs: json['durationMs'] as int,
        coverTrackId: json['coverTrackId'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'tracks': tracks,
        'albums': albums,
        'durationMs': durationMs,
        'coverTrackId': coverTrackId,
      };
}

class MusicArtistListResponse {
  final List<MusicArtist> items;

  const MusicArtistListResponse({
    required this.items,
  });

  factory MusicArtistListResponse.fromJson(Map<String, dynamic> json) => MusicArtistListResponse(
        items: (json['items'] as List<dynamic>).map((e) => MusicArtist.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class MusicStreamUrlResponse {
  final String url;
  final int expiresInSec;
  final bool transcoded;

  const MusicStreamUrlResponse({
    required this.url,
    required this.expiresInSec,
    required this.transcoded,
  });

  factory MusicStreamUrlResponse.fromJson(Map<String, dynamic> json) => MusicStreamUrlResponse(
        url: json['url'] as String,
        expiresInSec: json['expiresInSec'] as int,
        transcoded: json['transcoded'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'expiresInSec': expiresInSec,
        'transcoded': transcoded,
      };
}

class MusicStatsResponse {
  final int libraries;
  final int tracks;
  final int albums;
  final int artists;
  final int durationMs;

  const MusicStatsResponse({
    required this.libraries,
    required this.tracks,
    required this.albums,
    required this.artists,
    required this.durationMs,
  });

  factory MusicStatsResponse.fromJson(Map<String, dynamic> json) => MusicStatsResponse(
        libraries: json['libraries'] as int,
        tracks: json['tracks'] as int,
        albums: json['albums'] as int,
        artists: json['artists'] as int,
        durationMs: json['durationMs'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'libraries': libraries,
        'tracks': tracks,
        'albums': albums,
        'artists': artists,
        'durationMs': durationMs,
      };
}

class MusicCollection {
  final String id;
  final String name;
  final List<String> paths;
  final int tracks;
  final String? coverTrackId;
  final int createdAt;
  final int updatedAt;

  const MusicCollection({
    required this.id,
    required this.name,
    required this.paths,
    required this.tracks,
    required this.coverTrackId,
    required this.createdAt,
    required this.updatedAt,
  });

  factory MusicCollection.fromJson(Map<String, dynamic> json) => MusicCollection(
        id: json['id'] as String,
        name: json['name'] as String,
        paths: (json['paths'] as List<dynamic>).cast<String>(),
        tracks: json['tracks'] as int,
        coverTrackId: json['coverTrackId'] as String?,
        createdAt: json['createdAt'] as int,
        updatedAt: json['updatedAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'paths': paths,
        'tracks': tracks,
        'coverTrackId': coverTrackId,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };
}

class MusicCollectionListResponse {
  final List<MusicCollection> items;

  const MusicCollectionListResponse({
    required this.items,
  });

  factory MusicCollectionListResponse.fromJson(Map<String, dynamic> json) => MusicCollectionListResponse(
        items: (json['items'] as List<dynamic>).map((e) => MusicCollection.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class MusicCollectionBody {
  final String name;
  final List<String> paths;

  const MusicCollectionBody({
    required this.name,
    required this.paths,
  });

  factory MusicCollectionBody.fromJson(Map<String, dynamic> json) => MusicCollectionBody(
        name: json['name'] as String,
        paths: (json['paths'] as List<dynamic>).cast<String>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'paths': paths,
      };
}

class MusicCollectionUpdateBody {
  final String id;
  final String? name;
  final List<String>? paths;

  const MusicCollectionUpdateBody({
    required this.id,
    this.name,
    this.paths,
  });

  factory MusicCollectionUpdateBody.fromJson(Map<String, dynamic> json) => MusicCollectionUpdateBody(
        id: json['id'] as String,
        name: json['name'] == null ? null : json['name'] as String,
        paths: json['paths'] == null ? null : (json['paths'] as List<dynamic>).cast<String>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (name != null) 'name': name!,
        if (paths != null) 'paths': paths!,
      };
}

class MusicPlaylist {
  final String id;
  final String name;
  final int tracks;
  final String? coverTrackId;
  final int createdAt;

  const MusicPlaylist({
    required this.id,
    required this.name,
    required this.tracks,
    required this.coverTrackId,
    required this.createdAt,
  });

  factory MusicPlaylist.fromJson(Map<String, dynamic> json) => MusicPlaylist(
        id: json['id'] as String,
        name: json['name'] as String,
        tracks: json['tracks'] as int,
        coverTrackId: json['coverTrackId'] as String?,
        createdAt: json['createdAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'tracks': tracks,
        'coverTrackId': coverTrackId,
        'createdAt': createdAt,
      };
}

class MusicPlaylistListResponse {
  final List<MusicPlaylist> items;

  const MusicPlaylistListResponse({
    required this.items,
  });

  factory MusicPlaylistListResponse.fromJson(Map<String, dynamic> json) => MusicPlaylistListResponse(
        items: (json['items'] as List<dynamic>).map((e) => MusicPlaylist.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class MusicPlaylistCreateBody {
  final String name;
  final List<String>? trackIds;

  const MusicPlaylistCreateBody({
    required this.name,
    this.trackIds,
  });

  factory MusicPlaylistCreateBody.fromJson(Map<String, dynamic> json) => MusicPlaylistCreateBody(
        name: json['name'] as String,
        trackIds: json['trackIds'] == null ? null : (json['trackIds'] as List<dynamic>).cast<String>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        if (trackIds != null) 'trackIds': trackIds!,
      };
}

class MusicPlaylistMembersBody {
  final String playlistId;
  final List<String> trackIds;

  const MusicPlaylistMembersBody({
    required this.playlistId,
    required this.trackIds,
  });

  factory MusicPlaylistMembersBody.fromJson(Map<String, dynamic> json) => MusicPlaylistMembersBody(
        playlistId: json['playlistId'] as String,
        trackIds: (json['trackIds'] as List<dynamic>).cast<String>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'playlistId': playlistId,
        'trackIds': trackIds,
      };
}

class MusicPlaylistDeleteBody {
  final String playlistId;

  const MusicPlaylistDeleteBody({
    required this.playlistId,
  });

  factory MusicPlaylistDeleteBody.fromJson(Map<String, dynamic> json) => MusicPlaylistDeleteBody(
        playlistId: json['playlistId'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'playlistId': playlistId,
      };
}

class MusicPlaylistRenameBody {
  final String playlistId;
  final String name;

  const MusicPlaylistRenameBody({
    required this.playlistId,
    required this.name,
  });

  factory MusicPlaylistRenameBody.fromJson(Map<String, dynamic> json) => MusicPlaylistRenameBody(
        playlistId: json['playlistId'] as String,
        name: json['name'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'playlistId': playlistId,
        'name': name,
      };
}

class MusicAutoPlaylist {
  final String kind;
  final int count;
  final String? coverTrackId;

  const MusicAutoPlaylist({
    required this.kind,
    required this.count,
    required this.coverTrackId,
  });

  factory MusicAutoPlaylist.fromJson(Map<String, dynamic> json) => MusicAutoPlaylist(
        kind: json['kind'] as String,
        count: json['count'] as int,
        coverTrackId: json['coverTrackId'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
        'count': count,
        'coverTrackId': coverTrackId,
      };
}

class MusicAutoPlaylistListResponse {
  final List<MusicAutoPlaylist> items;

  const MusicAutoPlaylistListResponse({
    required this.items,
  });

  factory MusicAutoPlaylistListResponse.fromJson(Map<String, dynamic> json) => MusicAutoPlaylistListResponse(
        items: (json['items'] as List<dynamic>).map((e) => MusicAutoPlaylist.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class MusicAutoPlaylistTracksResponse {
  final List<MusicTrack> items;

  const MusicAutoPlaylistTracksResponse({
    required this.items,
  });

  factory MusicAutoPlaylistTracksResponse.fromJson(Map<String, dynamic> json) => MusicAutoPlaylistTracksResponse(
        items: (json['items'] as List<dynamic>).map((e) => MusicTrack.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class MusicOkResponse {
  final bool ok;

  const MusicOkResponse({
    required this.ok,
  });

  factory MusicOkResponse.fromJson(Map<String, dynamic> json) => MusicOkResponse(
        ok: json['ok'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
      };
}

class MusicErrorResponse {
  final String error;
  final String? message;
  final String? code;
  final String? traceId;
  final Map<String, dynamic>? details;

  const MusicErrorResponse({
    required this.error,
    this.message,
    this.code,
    this.traceId,
    this.details,
  });

  factory MusicErrorResponse.fromJson(Map<String, dynamic> json) => MusicErrorResponse(
        error: json['error'] as String,
        message: json['message'] == null ? null : json['message'] as String,
        code: json['code'] == null ? null : json['code'] as String,
        traceId: json['traceId'] == null ? null : json['traceId'] as String,
        details: json['details'] == null ? null : json['details'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'error': error,
        if (message != null) 'message': message!,
        if (code != null) 'code': code!,
        if (traceId != null) 'traceId': traceId!,
        if (details != null) 'details': details!,
      };
}

class MusicLyricsLine {
  final int? timeMs;
  final String text;
  final String? translation;

  const MusicLyricsLine({
    this.timeMs,
    required this.text,
    this.translation,
  });

  factory MusicLyricsLine.fromJson(Map<String, dynamic> json) => MusicLyricsLine(
        timeMs: json['timeMs'] == null ? null : json['timeMs'] as int,
        text: json['text'] as String,
        translation: json['translation'] == null ? null : json['translation'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (timeMs != null) 'timeMs': timeMs!,
        'text': text,
        if (translation != null) 'translation': translation!,
      };
}

class MusicLyricsResponse {
  final String source;
  final bool synced;
  final String? title;
  final String? artist;
  final String? album;
  final String? by;
  final List<MusicLyricsLine> lines;

  const MusicLyricsResponse({
    required this.source,
    required this.synced,
    this.title,
    this.artist,
    this.album,
    this.by,
    required this.lines,
  });

  factory MusicLyricsResponse.fromJson(Map<String, dynamic> json) => MusicLyricsResponse(
        source: json['source'] as String,
        synced: json['synced'] as bool,
        title: json['title'] == null ? null : json['title'] as String,
        artist: json['artist'] == null ? null : json['artist'] as String,
        album: json['album'] == null ? null : json['album'] as String,
        by: json['by'] == null ? null : json['by'] as String,
        lines: (json['lines'] as List<dynamic>).map((e) => MusicLyricsLine.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'source': source,
        'synced': synced,
        if (title != null) 'title': title!,
        if (artist != null) 'artist': artist!,
        if (album != null) 'album': album!,
        if (by != null) 'by': by!,
        'lines': lines.map((e) => e.toJson()).toList(),
      };
}

class MusicFavoriteBody {
  final String id;
  final bool favorite;

  const MusicFavoriteBody({
    required this.id,
    required this.favorite,
  });

  factory MusicFavoriteBody.fromJson(Map<String, dynamic> json) => MusicFavoriteBody(
        id: json['id'] as String,
        favorite: json['favorite'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'favorite': favorite,
      };
}

class MusicTrackRefBody {
  final String id;

  const MusicTrackRefBody({
    required this.id,
  });

  factory MusicTrackRefBody.fromJson(Map<String, dynamic> json) => MusicTrackRefBody(
        id: json['id'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
      };
}

class MusicStateItem {
  final String id;
  final String title;
  final String? artist;
  final String? album;
  final int? duration;
  final bool favorite;

  const MusicStateItem({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.favorite,
  });

  factory MusicStateItem.fromJson(Map<String, dynamic> json) => MusicStateItem(
        id: json['id'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String?,
        album: json['album'] as String?,
        duration: json['duration'] as int?,
        favorite: json['favorite'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'duration': duration,
        'favorite': favorite,
      };
}

class MusicStateList {
  final List<MusicStateItem> items;

  const MusicStateList({
    required this.items,
  });

  factory MusicStateList.fromJson(Map<String, dynamic> json) => MusicStateList(
        items: (json['items'] as List<dynamic>).map((e) => MusicStateItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class MusicHistoryItem {
  final String id;
  final String title;
  final String? artist;
  final String? album;
  final int? duration;
  final int playedAt;

  const MusicHistoryItem({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.playedAt,
  });

  factory MusicHistoryItem.fromJson(Map<String, dynamic> json) => MusicHistoryItem(
        id: json['id'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String?,
        album: json['album'] as String?,
        duration: json['duration'] as int?,
        playedAt: json['playedAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'duration': duration,
        'playedAt': playedAt,
      };
}

class MusicHistoryList {
  final List<MusicHistoryItem> items;

  const MusicHistoryList({
    required this.items,
  });

  factory MusicHistoryList.fromJson(Map<String, dynamic> json) => MusicHistoryList(
        items: (json['items'] as List<dynamic>).map((e) => MusicHistoryItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class MusicStateOk {
  final bool ok;

  const MusicStateOk({
    required this.ok,
  });

  factory MusicStateOk.fromJson(Map<String, dynamic> json) => MusicStateOk(
        ok: json['ok'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
      };
}

class PhotoOnThisDayYear {
  final int year;
  final String date;
  final int photoCount;
  final List<PhotoItem> items;

  const PhotoOnThisDayYear({
    required this.year,
    required this.date,
    required this.photoCount,
    required this.items,
  });

  factory PhotoOnThisDayYear.fromJson(Map<String, dynamic> json) => PhotoOnThisDayYear(
        year: json['year'] as int,
        date: json['date'] as String,
        photoCount: json['photoCount'] as int,
        items: (json['items'] as List<dynamic>).map((e) => PhotoItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'year': year,
        'date': date,
        'photoCount': photoCount,
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoOnThisDayResponse {
  final List<PhotoOnThisDayYear> years;

  const PhotoOnThisDayResponse({
    required this.years,
  });

  factory PhotoOnThisDayResponse.fromJson(Map<String, dynamic> json) => PhotoOnThisDayResponse(
        years: (json['years'] as List<dynamic>).map((e) => PhotoOnThisDayYear.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'years': years.map((e) => e.toJson()).toList(),
      };
}

class PhotoDeleteBody {
  final List<String> ids;
  final bool? toTrash;

  const PhotoDeleteBody({
    required this.ids,
    this.toTrash,
  });

  factory PhotoDeleteBody.fromJson(Map<String, dynamic> json) => PhotoDeleteBody(
        ids: (json['ids'] as List<dynamic>).cast<String>(),
        toTrash: json['toTrash'] == null ? null : json['toTrash'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ids': ids,
        if (toTrash != null) 'toTrash': toTrash!,
      };
}

class PhotoDeleteResponse {
  final int count;
  final bool trashed;
  final String? batchId;

  const PhotoDeleteResponse({
    required this.count,
    required this.trashed,
    this.batchId,
  });

  factory PhotoDeleteResponse.fromJson(Map<String, dynamic> json) => PhotoDeleteResponse(
        count: json['count'] as int,
        trashed: json['trashed'] as bool,
        batchId: json['batchId'] == null ? null : json['batchId'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'count': count,
        'trashed': trashed,
        if (batchId != null) 'batchId': batchId!,
      };
}

class PhotoCalendarMonth {
  final int month;
  final int count;
  final String? coverPath;

  const PhotoCalendarMonth({
    required this.month,
    required this.count,
    required this.coverPath,
  });

  factory PhotoCalendarMonth.fromJson(Map<String, dynamic> json) => PhotoCalendarMonth(
        month: json['month'] as int,
        count: json['count'] as int,
        coverPath: json['coverPath'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'month': month,
        'count': count,
        'coverPath': coverPath,
      };
}

class PhotoCalendarResponse {
  final int year;
  final int total;
  final List<PhotoCalendarMonth> months;

  const PhotoCalendarResponse({
    required this.year,
    required this.total,
    required this.months,
  });

  factory PhotoCalendarResponse.fromJson(Map<String, dynamic> json) => PhotoCalendarResponse(
        year: json['year'] as int,
        total: json['total'] as int,
        months: (json['months'] as List<dynamic>).map((e) => PhotoCalendarMonth.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'year': year,
        'total': total,
        'months': months.map((e) => e.toJson()).toList(),
      };
}

class PhotoYearCover {
  final int year;
  final int count;
  final String? coverPath;

  const PhotoYearCover({
    required this.year,
    required this.count,
    required this.coverPath,
  });

  factory PhotoYearCover.fromJson(Map<String, dynamic> json) => PhotoYearCover(
        year: json['year'] as int,
        count: json['count'] as int,
        coverPath: json['coverPath'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'year': year,
        'count': count,
        'coverPath': coverPath,
      };
}

class PhotoYearCoversResponse {
  final List<PhotoYearCover> years;

  const PhotoYearCoversResponse({
    required this.years,
  });

  factory PhotoYearCoversResponse.fromJson(Map<String, dynamic> json) => PhotoYearCoversResponse(
        years: (json['years'] as List<dynamic>).map((e) => PhotoYearCover.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'years': years.map((e) => e.toJson()).toList(),
      };
}

class PhotoScanPolicy {
  final bool autoWatch;
  final int verifyHours;
  final bool skipHidden;

  const PhotoScanPolicy({
    required this.autoWatch,
    required this.verifyHours,
    required this.skipHidden,
  });

  factory PhotoScanPolicy.fromJson(Map<String, dynamic> json) => PhotoScanPolicy(
        autoWatch: json['autoWatch'] as bool,
        verifyHours: json['verifyHours'] as int,
        skipHidden: json['skipHidden'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'autoWatch': autoWatch,
        'verifyHours': verifyHours,
        'skipHidden': skipHidden,
      };
}

class PhotoScanPolicyUpdateBody {
  final bool? autoWatch;
  final int? verifyHours;
  final bool? skipHidden;

  const PhotoScanPolicyUpdateBody({
    this.autoWatch,
    this.verifyHours,
    this.skipHidden,
  });

  factory PhotoScanPolicyUpdateBody.fromJson(Map<String, dynamic> json) => PhotoScanPolicyUpdateBody(
        autoWatch: json['autoWatch'] == null ? null : json['autoWatch'] as bool,
        verifyHours: json['verifyHours'] == null ? null : json['verifyHours'] as int,
        skipHidden: json['skipHidden'] == null ? null : json['skipHidden'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (autoWatch != null) 'autoWatch': autoWatch!,
        if (verifyHours != null) 'verifyHours': verifyHours!,
        if (skipHidden != null) 'skipHidden': skipHidden!,
      };
}

class PhotoSmartRulePlace {
  final double latitude;
  final double longitude;
  final double? radiusKm;

  const PhotoSmartRulePlace({
    required this.latitude,
    required this.longitude,
    this.radiusKm,
  });

  factory PhotoSmartRulePlace.fromJson(Map<String, dynamic> json) => PhotoSmartRulePlace(
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        radiusKm: json['radiusKm'] == null ? null : (json['radiusKm'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'latitude': latitude,
        'longitude': longitude,
        if (radiusKm != null) 'radiusKm': radiusKm!,
      };
}

class PhotoSmartRuleConditions {
  final String? scene;
  final String? activity;
  final String? faceClusterId;
  final PhotoSmartRulePlace? place;
  final int? from;
  final int? to;
  final bool? favorite;

  const PhotoSmartRuleConditions({
    this.scene,
    this.activity,
    this.faceClusterId,
    this.place,
    this.from,
    this.to,
    this.favorite,
  });

  factory PhotoSmartRuleConditions.fromJson(Map<String, dynamic> json) => PhotoSmartRuleConditions(
        scene: json['scene'] == null ? null : json['scene'] as String,
        activity: json['activity'] == null ? null : json['activity'] as String,
        faceClusterId: json['faceClusterId'] == null ? null : json['faceClusterId'] as String,
        place: json['place'] == null ? null : PhotoSmartRulePlace.fromJson(json['place'] as Map<String, dynamic>),
        from: json['from'] == null ? null : json['from'] as int,
        to: json['to'] == null ? null : json['to'] as int,
        favorite: json['favorite'] == null ? null : json['favorite'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (scene != null) 'scene': scene!,
        if (activity != null) 'activity': activity!,
        if (faceClusterId != null) 'faceClusterId': faceClusterId!,
        if (place != null) 'place': place!.toJson(),
        if (from != null) 'from': from!,
        if (to != null) 'to': to!,
        if (favorite != null) 'favorite': favorite!,
      };
}

class PhotoSmartRule {
  final String id;
  final String name;
  final PhotoSmartRuleConditions conditions;
  final int items;
  final String? coverPath;
  final int createdAt;
  final int updatedAt;

  const PhotoSmartRule({
    required this.id,
    required this.name,
    required this.conditions,
    required this.items,
    required this.coverPath,
    required this.createdAt,
    required this.updatedAt,
  });

  factory PhotoSmartRule.fromJson(Map<String, dynamic> json) => PhotoSmartRule(
        id: json['id'] as String,
        name: json['name'] as String,
        conditions: PhotoSmartRuleConditions.fromJson(json['conditions'] as Map<String, dynamic>),
        items: json['items'] as int,
        coverPath: json['coverPath'] as String?,
        createdAt: json['createdAt'] as int,
        updatedAt: json['updatedAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'conditions': conditions.toJson(),
        'items': items,
        'coverPath': coverPath,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };
}

class PhotoSmartRuleListResponse {
  final List<PhotoSmartRule> items;

  const PhotoSmartRuleListResponse({
    required this.items,
  });

  factory PhotoSmartRuleListResponse.fromJson(Map<String, dynamic> json) => PhotoSmartRuleListResponse(
        items: (json['items'] as List<dynamic>).map((e) => PhotoSmartRule.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoSmartRuleCreateBody {
  final String name;
  final PhotoSmartRuleConditions conditions;

  const PhotoSmartRuleCreateBody({
    required this.name,
    required this.conditions,
  });

  factory PhotoSmartRuleCreateBody.fromJson(Map<String, dynamic> json) => PhotoSmartRuleCreateBody(
        name: json['name'] as String,
        conditions: PhotoSmartRuleConditions.fromJson(json['conditions'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'conditions': conditions.toJson(),
      };
}

class PhotoSmartRuleUpdateBody {
  final String id;
  final String? name;
  final PhotoSmartRuleConditions? conditions;

  const PhotoSmartRuleUpdateBody({
    required this.id,
    this.name,
    this.conditions,
  });

  factory PhotoSmartRuleUpdateBody.fromJson(Map<String, dynamic> json) => PhotoSmartRuleUpdateBody(
        id: json['id'] as String,
        name: json['name'] == null ? null : json['name'] as String,
        conditions: json['conditions'] == null ? null : PhotoSmartRuleConditions.fromJson(json['conditions'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (name != null) 'name': name!,
        if (conditions != null) 'conditions': conditions!.toJson(),
      };
}

class PhotoSmartRuleDeleteBody {
  final String id;

  const PhotoSmartRuleDeleteBody({
    required this.id,
  });

  factory PhotoSmartRuleDeleteBody.fromJson(Map<String, dynamic> json) => PhotoSmartRuleDeleteBody(
        id: json['id'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
      };
}

class PhotoFilterBody {
  final PhotoSmartRuleConditions conditions;
  final String? q;
  final String? cursor;
  final int? limit;
  final dynamic order;

  const PhotoFilterBody({
    required this.conditions,
    this.q,
    this.cursor,
    this.limit,
    this.order,
  });

  factory PhotoFilterBody.fromJson(Map<String, dynamic> json) => PhotoFilterBody(
        conditions: PhotoSmartRuleConditions.fromJson(json['conditions'] as Map<String, dynamic>),
        q: json['q'] == null ? null : json['q'] as String,
        cursor: json['cursor'] == null ? null : json['cursor'] as String,
        limit: json['limit'] == null ? null : json['limit'] as int,
        order: json['order'] == null ? null : (json['order'] as dynamic),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'conditions': conditions.toJson(),
        if (q != null) 'q': q!,
        if (cursor != null) 'cursor': cursor!,
        if (limit != null) 'limit': limit!,
        if (order != null) 'order': order!,
      };
}

class PhotoFilterResponse {
  final List<PhotoItem> items;
  final String? nextCursor;
  final int? total;

  const PhotoFilterResponse({
    required this.items,
    required this.nextCursor,
    this.total,
  });

  factory PhotoFilterResponse.fromJson(Map<String, dynamic> json) => PhotoFilterResponse(
        items: (json['items'] as List<dynamic>).map((e) => PhotoItem.fromJson(e as Map<String, dynamic>)).toList(),
        nextCursor: json['nextCursor'] as String?,
        total: json['total'] == null ? null : json['total'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
        'nextCursor': nextCursor,
        if (total != null) 'total': total!,
      };
}

class PhotoLibraryItem {
  final String id;
  final String name;
  final String path;
  final int items;
  final int createdAt;
  final int? lastScanAt;

  const PhotoLibraryItem({
    required this.id,
    required this.name,
    required this.path,
    required this.items,
    required this.createdAt,
    required this.lastScanAt,
  });

  factory PhotoLibraryItem.fromJson(Map<String, dynamic> json) => PhotoLibraryItem(
        id: json['id'] as String,
        name: json['name'] as String,
        path: json['path'] as String,
        items: json['items'] as int,
        createdAt: json['createdAt'] as int,
        lastScanAt: json['lastScanAt'] as int?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'path': path,
        'items': items,
        'createdAt': createdAt,
        'lastScanAt': lastScanAt,
      };
}

class PhotoLibraryListResponse {
  final List<PhotoLibraryItem> items;

  const PhotoLibraryListResponse({
    required this.items,
  });

  factory PhotoLibraryListResponse.fromJson(Map<String, dynamic> json) => PhotoLibraryListResponse(
        items: (json['items'] as List<dynamic>).map((e) => PhotoLibraryItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoLibraryCreateBody {
  final String name;
  final String path;

  const PhotoLibraryCreateBody({
    required this.name,
    required this.path,
  });

  factory PhotoLibraryCreateBody.fromJson(Map<String, dynamic> json) => PhotoLibraryCreateBody(
        name: json['name'] as String,
        path: json['path'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'path': path,
      };
}

class PhotoLibraryRemoveBody {
  final String id;

  const PhotoLibraryRemoveBody({
    required this.id,
  });

  factory PhotoLibraryRemoveBody.fromJson(Map<String, dynamic> json) => PhotoLibraryRemoveBody(
        id: json['id'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
      };
}

class PhotoLibraryUpdateBody {
  final String path;

  const PhotoLibraryUpdateBody({
    required this.path,
  });

  factory PhotoLibraryUpdateBody.fromJson(Map<String, dynamic> json) => PhotoLibraryUpdateBody(
        path: json['path'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
      };
}

class PhotoScanBody {
  final String? libraryId;
  final int? limit;
  final bool? prune;
  final bool? force;

  const PhotoScanBody({
    this.libraryId,
    this.limit,
    this.prune,
    this.force,
  });

  factory PhotoScanBody.fromJson(Map<String, dynamic> json) => PhotoScanBody(
        libraryId: json['libraryId'] == null ? null : json['libraryId'] as String,
        limit: json['limit'] == null ? null : json['limit'] as int,
        prune: json['prune'] == null ? null : json['prune'] as bool,
        force: json['force'] == null ? null : json['force'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (libraryId != null) 'libraryId': libraryId!,
        if (limit != null) 'limit': limit!,
        if (prune != null) 'prune': prune!,
        if (force != null) 'force': force!,
      };
}

class PhotoScanResponse {
  final int libraries;
  final int images;
  final int added;
  final int updated;
  final int skipped;
  final int? missing;
  final int? pruned;

  const PhotoScanResponse({
    required this.libraries,
    required this.images,
    required this.added,
    required this.updated,
    required this.skipped,
    this.missing,
    this.pruned,
  });

  factory PhotoScanResponse.fromJson(Map<String, dynamic> json) => PhotoScanResponse(
        libraries: json['libraries'] as int,
        images: json['images'] as int,
        added: json['added'] as int,
        updated: json['updated'] as int,
        skipped: json['skipped'] as int,
        missing: json['missing'] == null ? null : json['missing'] as int,
        pruned: json['pruned'] == null ? null : json['pruned'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'libraries': libraries,
        'images': images,
        'added': added,
        'updated': updated,
        'skipped': skipped,
        if (missing != null) 'missing': missing!,
        if (pruned != null) 'pruned': pruned!,
      };
}

class PhotoItem {
  final String id;
  final String libraryId;
  final String path;
  final int takenAt;
  final int size;
  final int? width;
  final int? height;
  final String mime;
  final bool favorite;

  const PhotoItem({
    required this.id,
    required this.libraryId,
    required this.path,
    required this.takenAt,
    required this.size,
    required this.width,
    required this.height,
    required this.mime,
    required this.favorite,
  });

  factory PhotoItem.fromJson(Map<String, dynamic> json) => PhotoItem(
        id: json['id'] as String,
        libraryId: json['libraryId'] as String,
        path: json['path'] as String,
        takenAt: json['takenAt'] as int,
        size: json['size'] as int,
        width: json['width'] as int?,
        height: json['height'] as int?,
        mime: json['mime'] as String,
        favorite: json['favorite'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'libraryId': libraryId,
        'path': path,
        'takenAt': takenAt,
        'size': size,
        'width': width,
        'height': height,
        'mime': mime,
        'favorite': favorite,
      };
}

class PhotoTimelineResponse {
  final List<PhotoItem> items;
  final String? nextCursor;

  const PhotoTimelineResponse({
    required this.items,
    required this.nextCursor,
  });

  factory PhotoTimelineResponse.fromJson(Map<String, dynamic> json) => PhotoTimelineResponse(
        items: (json['items'] as List<dynamic>).map((e) => PhotoItem.fromJson(e as Map<String, dynamic>)).toList(),
        nextCursor: json['nextCursor'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
        'nextCursor': nextCursor,
      };
}

class PhotoFavoriteBody {
  final List<String> ids;
  final bool favorite;

  const PhotoFavoriteBody({
    required this.ids,
    required this.favorite,
  });

  factory PhotoFavoriteBody.fromJson(Map<String, dynamic> json) => PhotoFavoriteBody(
        ids: (json['ids'] as List<dynamic>).cast<String>(),
        favorite: json['favorite'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ids': ids,
        'favorite': favorite,
      };
}

class PhotoFavoriteResponse {
  final int updated;

  const PhotoFavoriteResponse({
    required this.updated,
  });

  factory PhotoFavoriteResponse.fromJson(Map<String, dynamic> json) => PhotoFavoriteResponse(
        updated: json['updated'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'updated': updated,
      };
}

class PhotoHybridSearchResponse {
  final List<PhotoItem> items;
  final int? nextOffset;
  final int total;
  final List<String> tags;
  final List<String> unmatched;
  final bool degraded;
  final String reason;

  const PhotoHybridSearchResponse({
    required this.items,
    required this.nextOffset,
    required this.total,
    required this.tags,
    required this.unmatched,
    required this.degraded,
    required this.reason,
  });

  factory PhotoHybridSearchResponse.fromJson(Map<String, dynamic> json) => PhotoHybridSearchResponse(
        items: (json['items'] as List<dynamic>).map((e) => PhotoItem.fromJson(e as Map<String, dynamic>)).toList(),
        nextOffset: json['nextOffset'] as int?,
        total: json['total'] as int,
        tags: (json['tags'] as List<dynamic>).cast<String>(),
        unmatched: (json['unmatched'] as List<dynamic>).cast<String>(),
        degraded: json['degraded'] as bool,
        reason: json['reason'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
        'nextOffset': nextOffset,
        'total': total,
        'tags': tags,
        'unmatched': unmatched,
        'degraded': degraded,
        'reason': reason,
      };
}

class PhotoStatsResponse {
  final int libraries;
  final int items;
  final int? earliest;
  final int? latest;
  final List<Map<String, dynamic>> byYear;
  final int videos;
  final int bytes;
  final int todayNew;
  final int activeDays;
  final List<Map<String, dynamic>> byDay;

  const PhotoStatsResponse({
    required this.libraries,
    required this.items,
    required this.earliest,
    required this.latest,
    required this.byYear,
    required this.videos,
    required this.bytes,
    required this.todayNew,
    required this.activeDays,
    required this.byDay,
  });

  factory PhotoStatsResponse.fromJson(Map<String, dynamic> json) => PhotoStatsResponse(
        libraries: json['libraries'] as int,
        items: json['items'] as int,
        earliest: json['earliest'] as int?,
        latest: json['latest'] as int?,
        byYear: (json['byYear'] as List<dynamic>).cast<Map<String, dynamic>>(),
        videos: json['videos'] as int,
        bytes: json['bytes'] as int,
        todayNew: json['todayNew'] as int,
        activeDays: json['activeDays'] as int,
        byDay: (json['byDay'] as List<dynamic>).cast<Map<String, dynamic>>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'libraries': libraries,
        'items': items,
        'earliest': earliest,
        'latest': latest,
        'byYear': byYear,
        'videos': videos,
        'bytes': bytes,
        'todayNew': todayNew,
        'activeDays': activeDays,
        'byDay': byDay,
      };
}

class PhotoAlbum {
  final String id;
  final String name;
  final int items;
  final String? coverPath;
  final int createdAt;
  final String? description;
  final String? coverItemId;
  final int sortOrder;

  const PhotoAlbum({
    required this.id,
    required this.name,
    required this.items,
    required this.coverPath,
    required this.createdAt,
    required this.description,
    required this.coverItemId,
    required this.sortOrder,
  });

  factory PhotoAlbum.fromJson(Map<String, dynamic> json) => PhotoAlbum(
        id: json['id'] as String,
        name: json['name'] as String,
        items: json['items'] as int,
        coverPath: json['coverPath'] as String?,
        createdAt: json['createdAt'] as int,
        description: json['description'] as String?,
        coverItemId: json['coverItemId'] as String?,
        sortOrder: json['sortOrder'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'items': items,
        'coverPath': coverPath,
        'createdAt': createdAt,
        'description': description,
        'coverItemId': coverItemId,
        'sortOrder': sortOrder,
      };
}

class PhotoAlbumListResponse {
  final List<PhotoAlbum> items;

  const PhotoAlbumListResponse({
    required this.items,
  });

  factory PhotoAlbumListResponse.fromJson(Map<String, dynamic> json) => PhotoAlbumListResponse(
        items: (json['items'] as List<dynamic>).map((e) => PhotoAlbum.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoAlbumCreateBody {
  final String name;
  final List<String>? itemIds;

  const PhotoAlbumCreateBody({
    required this.name,
    this.itemIds,
  });

  factory PhotoAlbumCreateBody.fromJson(Map<String, dynamic> json) => PhotoAlbumCreateBody(
        name: json['name'] as String,
        itemIds: json['itemIds'] == null ? null : (json['itemIds'] as List<dynamic>).cast<String>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        if (itemIds != null) 'itemIds': itemIds!,
      };
}

class PhotoAlbumMembersBody {
  final String albumId;
  final List<String> itemIds;

  const PhotoAlbumMembersBody({
    required this.albumId,
    required this.itemIds,
  });

  factory PhotoAlbumMembersBody.fromJson(Map<String, dynamic> json) => PhotoAlbumMembersBody(
        albumId: json['albumId'] as String,
        itemIds: (json['itemIds'] as List<dynamic>).cast<String>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'albumId': albumId,
        'itemIds': itemIds,
      };
}

class PhotoAlbumDeleteBody {
  final String albumId;

  const PhotoAlbumDeleteBody({
    required this.albumId,
  });

  factory PhotoAlbumDeleteBody.fromJson(Map<String, dynamic> json) => PhotoAlbumDeleteBody(
        albumId: json['albumId'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'albumId': albumId,
      };
}

class PhotoAlbumUpdateBody {
  final String albumId;
  final String? name;
  final String? description;
  final String? coverItemId;
  final int? sortOrder;

  const PhotoAlbumUpdateBody({
    required this.albumId,
    this.name,
    this.description,
    this.coverItemId,
    this.sortOrder,
  });

  factory PhotoAlbumUpdateBody.fromJson(Map<String, dynamic> json) => PhotoAlbumUpdateBody(
        albumId: json['albumId'] as String,
        name: json['name'] == null ? null : json['name'] as String,
        description: json['description'] == null ? null : json['description'] as String?,
        coverItemId: json['coverItemId'] == null ? null : json['coverItemId'] as String?,
        sortOrder: json['sortOrder'] == null ? null : json['sortOrder'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'albumId': albumId,
        if (name != null) 'name': name!,
        if (description != null) 'description': description!,
        if (coverItemId != null) 'coverItemId': coverItemId!,
        if (sortOrder != null) 'sortOrder': sortOrder!,
      };
}

class PhotoCollection {
  final String id;
  final String name;
  final int items;
  final String? coverPath;
  final int createdAt;

  const PhotoCollection({
    required this.id,
    required this.name,
    required this.items,
    required this.coverPath,
    required this.createdAt,
  });

  factory PhotoCollection.fromJson(Map<String, dynamic> json) => PhotoCollection(
        id: json['id'] as String,
        name: json['name'] as String,
        items: json['items'] as int,
        coverPath: json['coverPath'] as String?,
        createdAt: json['createdAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'items': items,
        'coverPath': coverPath,
        'createdAt': createdAt,
      };
}

class PhotoCollectionListResponse {
  final List<PhotoCollection> items;

  const PhotoCollectionListResponse({
    required this.items,
  });

  factory PhotoCollectionListResponse.fromJson(Map<String, dynamic> json) => PhotoCollectionListResponse(
        items: (json['items'] as List<dynamic>).map((e) => PhotoCollection.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoCollectionCreateBody {
  final String name;

  const PhotoCollectionCreateBody({
    required this.name,
  });

  factory PhotoCollectionCreateBody.fromJson(Map<String, dynamic> json) => PhotoCollectionCreateBody(
        name: json['name'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
      };
}

class PhotoCollectionDeleteBody {
  final String id;

  const PhotoCollectionDeleteBody({
    required this.id,
  });

  factory PhotoCollectionDeleteBody.fromJson(Map<String, dynamic> json) => PhotoCollectionDeleteBody(
        id: json['id'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
      };
}

class PhotoCollectionMembersBody {
  final String collectionId;
  final List<String> itemIds;

  const PhotoCollectionMembersBody({
    required this.collectionId,
    required this.itemIds,
  });

  factory PhotoCollectionMembersBody.fromJson(Map<String, dynamic> json) => PhotoCollectionMembersBody(
        collectionId: json['collectionId'] as String,
        itemIds: (json['itemIds'] as List<dynamic>).cast<String>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'collectionId': collectionId,
        'itemIds': itemIds,
      };
}

class PhotoGeoSetBody {
  final List<String> ids;
  final double latitude;
  final double longitude;

  const PhotoGeoSetBody({
    required this.ids,
    required this.latitude,
    required this.longitude,
  });

  factory PhotoGeoSetBody.fromJson(Map<String, dynamic> json) => PhotoGeoSetBody(
        ids: (json['ids'] as List<dynamic>).cast<String>(),
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ids': ids,
        'latitude': latitude,
        'longitude': longitude,
      };
}

class PhotoGeoSetResponse {
  final int updated;

  const PhotoGeoSetResponse({
    required this.updated,
  });

  factory PhotoGeoSetResponse.fromJson(Map<String, dynamic> json) => PhotoGeoSetResponse(
        updated: json['updated'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'updated': updated,
      };
}

class PhotoFolderItem {
  final String name;
  final String path;
  final int items;
  final String? coverPath;

  const PhotoFolderItem({
    required this.name,
    required this.path,
    required this.items,
    required this.coverPath,
  });

  factory PhotoFolderItem.fromJson(Map<String, dynamic> json) => PhotoFolderItem(
        name: json['name'] as String,
        path: json['path'] as String,
        items: json['items'] as int,
        coverPath: json['coverPath'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'path': path,
        'items': items,
        'coverPath': coverPath,
      };
}

class PhotoFolderList {
  final String path;
  final int files;
  final List<PhotoItem> fileItems;
  final List<PhotoFolderItem> dirs;

  const PhotoFolderList({
    required this.path,
    required this.files,
    required this.fileItems,
    required this.dirs,
  });

  factory PhotoFolderList.fromJson(Map<String, dynamic> json) => PhotoFolderList(
        path: json['path'] as String,
        files: json['files'] as int,
        fileItems: (json['fileItems'] as List<dynamic>).map((e) => PhotoItem.fromJson(e as Map<String, dynamic>)).toList(),
        dirs: (json['dirs'] as List<dynamic>).map((e) => PhotoFolderItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'files': files,
        'fileItems': fileItems.map((e) => e.toJson()).toList(),
        'dirs': dirs.map((e) => e.toJson()).toList(),
      };
}

class PhotoFolderRoot {
  final String id;
  final String name;
  final String path;
  final int items;
  final String? coverPath;

  const PhotoFolderRoot({
    required this.id,
    required this.name,
    required this.path,
    required this.items,
    required this.coverPath,
  });

  factory PhotoFolderRoot.fromJson(Map<String, dynamic> json) => PhotoFolderRoot(
        id: json['id'] as String,
        name: json['name'] as String,
        path: json['path'] as String,
        items: json['items'] as int,
        coverPath: json['coverPath'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'path': path,
        'items': items,
        'coverPath': coverPath,
      };
}

class PhotoFolderRoots {
  final List<PhotoFolderRoot> items;

  const PhotoFolderRoots({
    required this.items,
  });

  factory PhotoFolderRoots.fromJson(Map<String, dynamic> json) => PhotoFolderRoots(
        items: (json['items'] as List<dynamic>).map((e) => PhotoFolderRoot.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoPhashStatus {
  final bool running;
  final String phase;
  final int done;
  final int total;
  final int percent;
  final int groups;
  final int failed;
  final int threshold;

  const PhotoPhashStatus({
    required this.running,
    required this.phase,
    required this.done,
    required this.total,
    required this.percent,
    required this.groups,
    required this.failed,
    required this.threshold,
  });

  factory PhotoPhashStatus.fromJson(Map<String, dynamic> json) => PhotoPhashStatus(
        running: json['running'] as bool,
        phase: json['phase'] as String,
        done: json['done'] as int,
        total: json['total'] as int,
        percent: json['percent'] as int,
        groups: json['groups'] as int,
        failed: json['failed'] as int,
        threshold: json['threshold'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'running': running,
        'phase': phase,
        'done': done,
        'total': total,
        'percent': percent,
        'groups': groups,
        'failed': failed,
        'threshold': threshold,
      };
}

class PhotoPhashScanResponse {
  final bool started;

  const PhotoPhashScanResponse({
    required this.started,
  });

  factory PhotoPhashScanResponse.fromJson(Map<String, dynamic> json) => PhotoPhashScanResponse(
        started: json['started'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'started': started,
      };
}

class PhotoGeoReference {
  final String id;
  final String path;
  final int takenAt;
  final double latitude;
  final double longitude;
  final String place;

  const PhotoGeoReference({
    required this.id,
    required this.path,
    required this.takenAt,
    required this.latitude,
    required this.longitude,
    required this.place,
  });

  factory PhotoGeoReference.fromJson(Map<String, dynamic> json) => PhotoGeoReference(
        id: json['id'] as String,
        path: json['path'] as String,
        takenAt: json['takenAt'] as int,
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        place: json['place'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'path': path,
        'takenAt': takenAt,
        'latitude': latitude,
        'longitude': longitude,
        'place': place,
      };
}

class PhotoGeoReferenceList {
  final List<PhotoGeoReference> items;

  const PhotoGeoReferenceList({
    required this.items,
  });

  factory PhotoGeoReferenceList.fromJson(Map<String, dynamic> json) => PhotoGeoReferenceList(
        items: (json['items'] as List<dynamic>).map((e) => PhotoGeoReference.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoGeoVisionCandidate {
  final String id;
  final String photoId;
  final String path;
  final String anchorId;
  final String anchorPath;
  final double latitude;
  final double longitude;
  final double similarity;
  final String status;

  const PhotoGeoVisionCandidate({
    required this.id,
    required this.photoId,
    required this.path,
    required this.anchorId,
    required this.anchorPath,
    required this.latitude,
    required this.longitude,
    required this.similarity,
    required this.status,
  });

  factory PhotoGeoVisionCandidate.fromJson(Map<String, dynamic> json) => PhotoGeoVisionCandidate(
        id: json['id'] as String,
        photoId: json['photoId'] as String,
        path: json['path'] as String,
        anchorId: json['anchorId'] as String,
        anchorPath: json['anchorPath'] as String,
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        similarity: (json['similarity'] as num).toDouble(),
        status: json['status'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'photoId': photoId,
        'path': path,
        'anchorId': anchorId,
        'anchorPath': anchorPath,
        'latitude': latitude,
        'longitude': longitude,
        'similarity': similarity,
        'status': status,
      };
}

class PhotoGeoVisionList {
  final List<PhotoGeoVisionCandidate> items;
  final int total;

  const PhotoGeoVisionList({
    required this.items,
    required this.total,
  });

  factory PhotoGeoVisionList.fromJson(Map<String, dynamic> json) => PhotoGeoVisionList(
        items: (json['items'] as List<dynamic>).map((e) => PhotoGeoVisionCandidate.fromJson(e as Map<String, dynamic>)).toList(),
        total: json['total'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
        'total': total,
      };
}

class PhotoGeoVisionStatus {
  final bool running;
  final int done;
  final int total;
  final int generated;

  const PhotoGeoVisionStatus({
    required this.running,
    required this.done,
    required this.total,
    required this.generated,
  });

  factory PhotoGeoVisionStatus.fromJson(Map<String, dynamic> json) => PhotoGeoVisionStatus(
        running: json['running'] as bool,
        done: json['done'] as int,
        total: json['total'] as int,
        generated: json['generated'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'running': running,
        'done': done,
        'total': total,
        'generated': generated,
      };
}

class PhotoGeoVisionApplyBody {
  final String id;
  final double? latitude;
  final double? longitude;

  const PhotoGeoVisionApplyBody({
    required this.id,
    this.latitude,
    this.longitude,
  });

  factory PhotoGeoVisionApplyBody.fromJson(Map<String, dynamic> json) => PhotoGeoVisionApplyBody(
        id: json['id'] as String,
        latitude: json['latitude'] == null ? null : (json['latitude'] as num).toDouble(),
        longitude: json['longitude'] == null ? null : (json['longitude'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (latitude != null) 'latitude': latitude!,
        if (longitude != null) 'longitude': longitude!,
      };
}

class PhotoGeoVisionRejectBody {
  final String id;

  const PhotoGeoVisionRejectBody({
    required this.id,
  });

  factory PhotoGeoVisionRejectBody.fromJson(Map<String, dynamic> json) => PhotoGeoVisionRejectBody(
        id: json['id'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
      };
}

class PhotoModelItem {
  final String name;
  final int size;
  final int modified;

  const PhotoModelItem({
    required this.name,
    required this.size,
    required this.modified,
  });

  factory PhotoModelItem.fromJson(Map<String, dynamic> json) => PhotoModelItem(
        name: json['name'] as String,
        size: json['size'] as int,
        modified: json['modified'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'size': size,
        'modified': modified,
      };
}

class PhotoModelList {
  final String dir;
  final bool exists;
  final List<PhotoModelItem> items;

  const PhotoModelList({
    required this.dir,
    required this.exists,
    required this.items,
  });

  factory PhotoModelList.fromJson(Map<String, dynamic> json) => PhotoModelList(
        dir: json['dir'] as String,
        exists: json['exists'] as bool,
        items: (json['items'] as List<dynamic>).map((e) => PhotoModelItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'dir': dir,
        'exists': exists,
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoFsRoots {
  final List<String> items;

  const PhotoFsRoots({
    required this.items,
  });

  factory PhotoFsRoots.fromJson(Map<String, dynamic> json) => PhotoFsRoots(
        items: (json['items'] as List<dynamic>).cast<String>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items,
      };
}

class PhotoFsDirItem {
  final String name;
  final String path;

  const PhotoFsDirItem({
    required this.name,
    required this.path,
  });

  factory PhotoFsDirItem.fromJson(Map<String, dynamic> json) => PhotoFsDirItem(
        name: json['name'] as String,
        path: json['path'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'path': path,
      };
}

class PhotoFsList {
  final String path;
  final String? parent;
  final List<PhotoFsDirItem> dirs;

  const PhotoFsList({
    required this.path,
    required this.parent,
    required this.dirs,
  });

  factory PhotoFsList.fromJson(Map<String, dynamic> json) => PhotoFsList(
        path: json['path'] as String,
        parent: json['parent'] as String?,
        dirs: (json['dirs'] as List<dynamic>).map((e) => PhotoFsDirItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'parent': parent,
        'dirs': dirs.map((e) => e.toJson()).toList(),
      };
}

class PhotoOkResponse {
  final bool ok;

  const PhotoOkResponse({
    required this.ok,
  });

  factory PhotoOkResponse.fromJson(Map<String, dynamic> json) => PhotoOkResponse(
        ok: json['ok'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
      };
}

class PhotoErrorResponse {
  final String error;
  final String? message;
  final String? code;
  final String? traceId;
  final Map<String, dynamic>? details;

  const PhotoErrorResponse({
    required this.error,
    this.message,
    this.code,
    this.traceId,
    this.details,
  });

  factory PhotoErrorResponse.fromJson(Map<String, dynamic> json) => PhotoErrorResponse(
        error: json['error'] as String,
        message: json['message'] == null ? null : json['message'] as String,
        code: json['code'] == null ? null : json['code'] as String,
        traceId: json['traceId'] == null ? null : json['traceId'] as String,
        details: json['details'] == null ? null : json['details'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'error': error,
        if (message != null) 'message': message!,
        if (code != null) 'code': code!,
        if (traceId != null) 'traceId': traceId!,
        if (details != null) 'details': details!,
      };
}

class PhotoHomeLibraryStat {
  final int photos;
  final int videos;
  final int todayNew;
  final int bytes;

  const PhotoHomeLibraryStat({
    required this.photos,
    required this.videos,
    required this.todayNew,
    required this.bytes,
  });

  factory PhotoHomeLibraryStat.fromJson(Map<String, dynamic> json) => PhotoHomeLibraryStat(
        photos: json['photos'] as int,
        videos: json['videos'] as int,
        todayNew: json['todayNew'] as int,
        bytes: json['bytes'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'photos': photos,
        'videos': videos,
        'todayNew': todayNew,
        'bytes': bytes,
      };
}

class PhotoHomeHeat {
  final int total;
  final int activeDays;
  final List<Map<String, dynamic>> byYear;
  final List<Map<String, dynamic>> byDay;
  final Map<String, dynamic>? peakMonth;

  const PhotoHomeHeat({
    required this.total,
    required this.activeDays,
    required this.byYear,
    required this.byDay,
    required this.peakMonth,
  });

  factory PhotoHomeHeat.fromJson(Map<String, dynamic> json) => PhotoHomeHeat(
        total: json['total'] as int,
        activeDays: json['activeDays'] as int,
        byYear: (json['byYear'] as List<dynamic>).cast<Map<String, dynamic>>(),
        byDay: (json['byDay'] as List<dynamic>).cast<Map<String, dynamic>>(),
        peakMonth: json['peakMonth'] as Map<String, dynamic>?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'total': total,
        'activeDays': activeDays,
        'byYear': byYear,
        'byDay': byDay,
        'peakMonth': peakMonth,
      };
}

class PhotoHomeFootprint {
  final int cities;
  final int places;
  final int days;

  const PhotoHomeFootprint({
    required this.cities,
    required this.places,
    required this.days,
  });

  factory PhotoHomeFootprint.fromJson(Map<String, dynamic> json) => PhotoHomeFootprint(
        cities: json['cities'] as int,
        places: json['places'] as int,
        days: json['days'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'cities': cities,
        'places': places,
        'days': days,
      };
}

class PhotoHomePerson {
  final String id;
  final String? name;
  final int size;
  final String? coverPath;

  const PhotoHomePerson({
    required this.id,
    required this.name,
    required this.size,
    required this.coverPath,
  });

  factory PhotoHomePerson.fromJson(Map<String, dynamic> json) => PhotoHomePerson(
        id: json['id'] as String,
        name: json['name'] as String?,
        size: json['size'] as int,
        coverPath: json['coverPath'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'size': size,
        'coverPath': coverPath,
      };
}

class PhotoHomePeople {
  final List<PhotoHomePerson> items;
  final int pending;

  const PhotoHomePeople({
    required this.items,
    required this.pending,
  });

  factory PhotoHomePeople.fromJson(Map<String, dynamic> json) => PhotoHomePeople(
        items: (json['items'] as List<dynamic>).map((e) => PhotoHomePerson.fromJson(e as Map<String, dynamic>)).toList(),
        pending: json['pending'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
        'pending': pending,
      };
}

class PhotoHomeOnThisDay {
  final String date;
  final int year;
  final int photoCount;
  final List<PhotoItem> items;

  const PhotoHomeOnThisDay({
    required this.date,
    required this.year,
    required this.photoCount,
    required this.items,
  });

  factory PhotoHomeOnThisDay.fromJson(Map<String, dynamic> json) => PhotoHomeOnThisDay(
        date: json['date'] as String,
        year: json['year'] as int,
        photoCount: json['photoCount'] as int,
        items: (json['items'] as List<dynamic>).map((e) => PhotoItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'date': date,
        'year': year,
        'photoCount': photoCount,
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoHomeSummary {
  final PhotoHomeLibraryStat library;
  final PhotoHomeHeat heat;
  final PhotoHomeFootprint footprint;
  final PhotoHomePeople people;
  final List<PhotoHomeOnThisDay> onThisDay;

  const PhotoHomeSummary({
    required this.library,
    required this.heat,
    required this.footprint,
    required this.people,
    required this.onThisDay,
  });

  factory PhotoHomeSummary.fromJson(Map<String, dynamic> json) => PhotoHomeSummary(
        library: PhotoHomeLibraryStat.fromJson(json['library'] as Map<String, dynamic>),
        heat: PhotoHomeHeat.fromJson(json['heat'] as Map<String, dynamic>),
        footprint: PhotoHomeFootprint.fromJson(json['footprint'] as Map<String, dynamic>),
        people: PhotoHomePeople.fromJson(json['people'] as Map<String, dynamic>),
        onThisDay: (json['onThisDay'] as List<dynamic>).map((e) => PhotoHomeOnThisDay.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'library': library.toJson(),
        'heat': heat.toJson(),
        'footprint': footprint.toJson(),
        'people': people.toJson(),
        'onThisDay': onThisDay.map((e) => e.toJson()).toList(),
      };
}

class PhotoAiTuning {
  final double matchSim;
  final int minVotes;
  final int threads;

  const PhotoAiTuning({
    required this.matchSim,
    required this.minVotes,
    required this.threads,
  });

  factory PhotoAiTuning.fromJson(Map<String, dynamic> json) => PhotoAiTuning(
        matchSim: (json['matchSim'] as num).toDouble(),
        minVotes: json['minVotes'] as int,
        threads: json['threads'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'matchSim': matchSim,
        'minVotes': minVotes,
        'threads': threads,
      };
}

class PhotoAiConfig {
  final bool faceEnabled;
  final bool placeEnabled;
  final bool activityEnabled;
  final bool ocrEnabled;
  final bool similarEnabled;
  final int faceMinShowCount;
  final bool gpuPrefer;
  final bool paused;
  final PhotoAiTuning tuning;

  const PhotoAiConfig({
    required this.faceEnabled,
    required this.placeEnabled,
    required this.activityEnabled,
    required this.ocrEnabled,
    required this.similarEnabled,
    required this.faceMinShowCount,
    required this.gpuPrefer,
    required this.paused,
    required this.tuning,
  });

  factory PhotoAiConfig.fromJson(Map<String, dynamic> json) => PhotoAiConfig(
        faceEnabled: json['faceEnabled'] as bool,
        placeEnabled: json['placeEnabled'] as bool,
        activityEnabled: json['activityEnabled'] as bool,
        ocrEnabled: json['ocrEnabled'] as bool,
        similarEnabled: json['similarEnabled'] as bool,
        faceMinShowCount: json['faceMinShowCount'] as int,
        gpuPrefer: json['gpuPrefer'] as bool,
        paused: json['paused'] as bool,
        tuning: PhotoAiTuning.fromJson(json['tuning'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'faceEnabled': faceEnabled,
        'placeEnabled': placeEnabled,
        'activityEnabled': activityEnabled,
        'ocrEnabled': ocrEnabled,
        'similarEnabled': similarEnabled,
        'faceMinShowCount': faceMinShowCount,
        'gpuPrefer': gpuPrefer,
        'paused': paused,
        'tuning': tuning.toJson(),
      };
}

class PhotoAiProgress {
  final int face;
  final int place;
  final int activity;
  final int ocr;
  final int clip;
  final int similarScan;
  final int similarCompare;

  const PhotoAiProgress({
    required this.face,
    required this.place,
    required this.activity,
    required this.ocr,
    required this.clip,
    required this.similarScan,
    required this.similarCompare,
  });

  factory PhotoAiProgress.fromJson(Map<String, dynamic> json) => PhotoAiProgress(
        face: json['face'] as int,
        place: json['place'] as int,
        activity: json['activity'] as int,
        ocr: json['ocr'] as int,
        clip: json['clip'] as int,
        similarScan: json['similarScan'] as int,
        similarCompare: json['similarCompare'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'face': face,
        'place': place,
        'activity': activity,
        'ocr': ocr,
        'clip': clip,
        'similarScan': similarScan,
        'similarCompare': similarCompare,
      };
}

class PhotoAiQueueJob {
  final String key;
  final String label;
  final String status;
  final int pending;
  final int done;
  final int total;
  final int percent;

  const PhotoAiQueueJob({
    required this.key,
    required this.label,
    required this.status,
    required this.pending,
    required this.done,
    required this.total,
    required this.percent,
  });

  factory PhotoAiQueueJob.fromJson(Map<String, dynamic> json) => PhotoAiQueueJob(
        key: json['key'] as String,
        label: json['label'] as String,
        status: json['status'] as String,
        pending: json['pending'] as int,
        done: json['done'] as int,
        total: json['total'] as int,
        percent: json['percent'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'label': label,
        'status': status,
        'pending': pending,
        'done': done,
        'total': total,
        'percent': percent,
      };
}

class PhotoAiQueue {
  final bool paused;
  final List<PhotoAiQueueJob> jobs;

  const PhotoAiQueue({
    required this.paused,
    required this.jobs,
  });

  factory PhotoAiQueue.fromJson(Map<String, dynamic> json) => PhotoAiQueue(
        paused: json['paused'] as bool,
        jobs: (json['jobs'] as List<dynamic>).map((e) => PhotoAiQueueJob.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'paused': paused,
        'jobs': jobs.map((e) => e.toJson()).toList(),
      };
}

class PhotoAiSettings {
  final PhotoAiConfig config;
  final PhotoAiProgress progress;
  final PhotoAiQueue queue;

  const PhotoAiSettings({
    required this.config,
    required this.progress,
    required this.queue,
  });

  factory PhotoAiSettings.fromJson(Map<String, dynamic> json) => PhotoAiSettings(
        config: PhotoAiConfig.fromJson(json['config'] as Map<String, dynamic>),
        progress: PhotoAiProgress.fromJson(json['progress'] as Map<String, dynamic>),
        queue: PhotoAiQueue.fromJson(json['queue'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'config': config.toJson(),
        'progress': progress.toJson(),
        'queue': queue.toJson(),
      };
}

class PhotoAiConfigBody {
  final bool? faceEnabled;
  final bool? placeEnabled;
  final bool? activityEnabled;
  final bool? ocrEnabled;
  final bool? similarEnabled;
  final int? faceMinShowCount;
  final bool? gpuPrefer;
  final bool? paused;
  final double? matchSim;
  final int? minVotes;
  final int? threads;

  const PhotoAiConfigBody({
    this.faceEnabled,
    this.placeEnabled,
    this.activityEnabled,
    this.ocrEnabled,
    this.similarEnabled,
    this.faceMinShowCount,
    this.gpuPrefer,
    this.paused,
    this.matchSim,
    this.minVotes,
    this.threads,
  });

  factory PhotoAiConfigBody.fromJson(Map<String, dynamic> json) => PhotoAiConfigBody(
        faceEnabled: json['faceEnabled'] == null ? null : json['faceEnabled'] as bool,
        placeEnabled: json['placeEnabled'] == null ? null : json['placeEnabled'] as bool,
        activityEnabled: json['activityEnabled'] == null ? null : json['activityEnabled'] as bool,
        ocrEnabled: json['ocrEnabled'] == null ? null : json['ocrEnabled'] as bool,
        similarEnabled: json['similarEnabled'] == null ? null : json['similarEnabled'] as bool,
        faceMinShowCount: json['faceMinShowCount'] == null ? null : json['faceMinShowCount'] as int,
        gpuPrefer: json['gpuPrefer'] == null ? null : json['gpuPrefer'] as bool,
        paused: json['paused'] == null ? null : json['paused'] as bool,
        matchSim: json['matchSim'] == null ? null : (json['matchSim'] as num).toDouble(),
        minVotes: json['minVotes'] == null ? null : json['minVotes'] as int,
        threads: json['threads'] == null ? null : json['threads'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (faceEnabled != null) 'faceEnabled': faceEnabled!,
        if (placeEnabled != null) 'placeEnabled': placeEnabled!,
        if (activityEnabled != null) 'activityEnabled': activityEnabled!,
        if (ocrEnabled != null) 'ocrEnabled': ocrEnabled!,
        if (similarEnabled != null) 'similarEnabled': similarEnabled!,
        if (faceMinShowCount != null) 'faceMinShowCount': faceMinShowCount!,
        if (gpuPrefer != null) 'gpuPrefer': gpuPrefer!,
        if (paused != null) 'paused': paused!,
        if (matchSim != null) 'matchSim': matchSim!,
        if (minVotes != null) 'minVotes': minVotes!,
        if (threads != null) 'threads': threads!,
      };
}

class PhotoAiTuningBody {
  final double matchSim;
  final int minVotes;
  final int threads;

  const PhotoAiTuningBody({
    required this.matchSim,
    required this.minVotes,
    required this.threads,
  });

  factory PhotoAiTuningBody.fromJson(Map<String, dynamic> json) => PhotoAiTuningBody(
        matchSim: (json['matchSim'] as num).toDouble(),
        minVotes: json['minVotes'] as int,
        threads: json['threads'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'matchSim': matchSim,
        'minVotes': minVotes,
        'threads': threads,
      };
}

class PhotoAiTuningResponse {
  final bool ok;
  final bool restarted;

  const PhotoAiTuningResponse({
    required this.ok,
    required this.restarted,
  });

  factory PhotoAiTuningResponse.fromJson(Map<String, dynamic> json) => PhotoAiTuningResponse(
        ok: json['ok'] as bool,
        restarted: json['restarted'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        'restarted': restarted,
      };
}

class PhotoAiQueuePauseBody {
  final bool paused;

  const PhotoAiQueuePauseBody({
    required this.paused,
  });

  factory PhotoAiQueuePauseBody.fromJson(Map<String, dynamic> json) => PhotoAiQueuePauseBody(
        paused: json['paused'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'paused': paused,
      };
}

class PhotoAiOpResponse {
  final bool ok;
  final int count;
  final String? message;

  const PhotoAiOpResponse({
    required this.ok,
    required this.count,
    this.message,
  });

  factory PhotoAiOpResponse.fromJson(Map<String, dynamic> json) => PhotoAiOpResponse(
        ok: json['ok'] as bool,
        count: json['count'] as int,
        message: json['message'] == null ? null : json['message'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        'count': count,
        if (message != null) 'message': message!,
      };
}

class PhotoAiResetBody {
  final dynamic kind;

  const PhotoAiResetBody({
    required this.kind,
  });

  factory PhotoAiResetBody.fromJson(Map<String, dynamic> json) => PhotoAiResetBody(
        kind: (json['kind'] as dynamic),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
      };
}

class PhotoMcpStatus {
  final bool enabled;
  final String tokenMasked;
  final String uid;
  final List<String> tools;
  final String baseUrl;

  const PhotoMcpStatus({
    required this.enabled,
    required this.tokenMasked,
    required this.uid,
    required this.tools,
    required this.baseUrl,
  });

  factory PhotoMcpStatus.fromJson(Map<String, dynamic> json) => PhotoMcpStatus(
        enabled: json['enabled'] as bool,
        tokenMasked: json['tokenMasked'] as String,
        uid: json['uid'] as String,
        tools: (json['tools'] as List<dynamic>).cast<String>(),
        baseUrl: json['baseUrl'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'tokenMasked': tokenMasked,
        'uid': uid,
        'tools': tools,
        'baseUrl': baseUrl,
      };
}

class PhotoMcpConfigBody {
  final bool? enabled;
  final String? uid;

  const PhotoMcpConfigBody({
    this.enabled,
    this.uid,
  });

  factory PhotoMcpConfigBody.fromJson(Map<String, dynamic> json) => PhotoMcpConfigBody(
        enabled: json['enabled'] == null ? null : json['enabled'] as bool,
        uid: json['uid'] == null ? null : json['uid'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (enabled != null) 'enabled': enabled!,
        if (uid != null) 'uid': uid!,
      };
}

class PhotoMcpTokenResponse {
  final String token;

  const PhotoMcpTokenResponse({
    required this.token,
  });

  factory PhotoMcpTokenResponse.fromJson(Map<String, dynamic> json) => PhotoMcpTokenResponse(
        token: json['token'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'token': token,
      };
}

class PhotoMemoryItem {
  final String date;
  final int photoCount;
  final String coverPath;
  final String place;
  final List<String> scenes;
  final List<String> activities;
  final List<String> people;
  final String note;
  final String status;
  final int updatedAt;

  const PhotoMemoryItem({
    required this.date,
    required this.photoCount,
    required this.coverPath,
    required this.place,
    required this.scenes,
    required this.activities,
    required this.people,
    required this.note,
    required this.status,
    required this.updatedAt,
  });

  factory PhotoMemoryItem.fromJson(Map<String, dynamic> json) => PhotoMemoryItem(
        date: json['date'] as String,
        photoCount: json['photoCount'] as int,
        coverPath: json['coverPath'] as String,
        place: json['place'] as String,
        scenes: (json['scenes'] as List<dynamic>).cast<String>(),
        activities: (json['activities'] as List<dynamic>).cast<String>(),
        people: (json['people'] as List<dynamic>).cast<String>(),
        note: json['note'] as String,
        status: json['status'] as String,
        updatedAt: json['updatedAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'date': date,
        'photoCount': photoCount,
        'coverPath': coverPath,
        'place': place,
        'scenes': scenes,
        'activities': activities,
        'people': people,
        'note': note,
        'status': status,
        'updatedAt': updatedAt,
      };
}

class PhotoMemoryChapter {
  final int year;
  final String coverPath;
  final int photoCount;
  final String start;
  final String end;

  const PhotoMemoryChapter({
    required this.year,
    required this.coverPath,
    required this.photoCount,
    required this.start,
    required this.end,
  });

  factory PhotoMemoryChapter.fromJson(Map<String, dynamic> json) => PhotoMemoryChapter(
        year: json['year'] as int,
        coverPath: json['coverPath'] as String,
        photoCount: json['photoCount'] as int,
        start: json['start'] as String,
        end: json['end'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'year': year,
        'coverPath': coverPath,
        'photoCount': photoCount,
        'start': start,
        'end': end,
      };
}

class PhotoMemoryList {
  final List<PhotoMemoryItem> candidates;
  final List<PhotoMemoryItem> memories;
  final List<PhotoMemoryItem> ignored;
  final List<PhotoMemoryChapter> chapters;

  const PhotoMemoryList({
    required this.candidates,
    required this.memories,
    required this.ignored,
    required this.chapters,
  });

  factory PhotoMemoryList.fromJson(Map<String, dynamic> json) => PhotoMemoryList(
        candidates: (json['candidates'] as List<dynamic>).map((e) => PhotoMemoryItem.fromJson(e as Map<String, dynamic>)).toList(),
        memories: (json['memories'] as List<dynamic>).map((e) => PhotoMemoryItem.fromJson(e as Map<String, dynamic>)).toList(),
        ignored: (json['ignored'] as List<dynamic>).map((e) => PhotoMemoryItem.fromJson(e as Map<String, dynamic>)).toList(),
        chapters: (json['chapters'] as List<dynamic>).map((e) => PhotoMemoryChapter.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'candidates': candidates.map((e) => e.toJson()).toList(),
        'memories': memories.map((e) => e.toJson()).toList(),
        'ignored': ignored.map((e) => e.toJson()).toList(),
        'chapters': chapters.map((e) => e.toJson()).toList(),
      };
}

class PhotoMemorySaveBody {
  final String date;
  final String? note;

  const PhotoMemorySaveBody({
    required this.date,
    this.note,
  });

  factory PhotoMemorySaveBody.fromJson(Map<String, dynamic> json) => PhotoMemorySaveBody(
        date: json['date'] as String,
        note: json['note'] == null ? null : json['note'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'date': date,
        if (note != null) 'note': note!,
      };
}

class PhotoMemoryTargetBody {
  final String date;

  const PhotoMemoryTargetBody({
    required this.date,
  });

  factory PhotoMemoryTargetBody.fromJson(Map<String, dynamic> json) => PhotoMemoryTargetBody(
        date: json['date'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'date': date,
      };
}

class PhotoScanTask {
  final String taskId;
  final bool reused;

  const PhotoScanTask({
    required this.taskId,
    required this.reused,
  });

  factory PhotoScanTask.fromJson(Map<String, dynamic> json) => PhotoScanTask(
        taskId: json['taskId'] as String,
        reused: json['reused'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'taskId': taskId,
        'reused': reused,
      };
}

class PhotoAiScanBody {
  final bool? force;
  final bool? ocr;
  final bool? activity;
  final int? limit;

  const PhotoAiScanBody({
    this.force,
    this.ocr,
    this.activity,
    this.limit,
  });

  factory PhotoAiScanBody.fromJson(Map<String, dynamic> json) => PhotoAiScanBody(
        force: json['force'] == null ? null : json['force'] as bool,
        ocr: json['ocr'] == null ? null : json['ocr'] as bool,
        activity: json['activity'] == null ? null : json['activity'] as bool,
        limit: json['limit'] == null ? null : json['limit'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (force != null) 'force': force!,
        if (ocr != null) 'ocr': ocr!,
        if (activity != null) 'activity': activity!,
        if (limit != null) 'limit': limit!,
      };
}

class PhotoAiScanResponse {
  final String jobId;
  final bool reused;

  const PhotoAiScanResponse({
    required this.jobId,
    required this.reused,
  });

  factory PhotoAiScanResponse.fromJson(Map<String, dynamic> json) => PhotoAiScanResponse(
        jobId: json['jobId'] as String,
        reused: json['reused'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'jobId': jobId,
        'reused': reused,
      };
}

class PhotoAiAnalyzeBody {
  final String? libraryId;
  final int? limit;
  final bool? force;
  final bool? ocr;
  final bool? activity;

  const PhotoAiAnalyzeBody({
    this.libraryId,
    this.limit,
    this.force,
    this.ocr,
    this.activity,
  });

  factory PhotoAiAnalyzeBody.fromJson(Map<String, dynamic> json) => PhotoAiAnalyzeBody(
        libraryId: json['libraryId'] == null ? null : json['libraryId'] as String,
        limit: json['limit'] == null ? null : json['limit'] as int,
        force: json['force'] == null ? null : json['force'] as bool,
        ocr: json['ocr'] == null ? null : json['ocr'] as bool,
        activity: json['activity'] == null ? null : json['activity'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (libraryId != null) 'libraryId': libraryId!,
        if (limit != null) 'limit': limit!,
        if (force != null) 'force': force!,
        if (ocr != null) 'ocr': ocr!,
        if (activity != null) 'activity': activity!,
      };
}

class PhotoAiAnalyzeResponse {
  final int processed;
  final int skipped;
  final int faces;
  final int scenes;
  final int ocr;
  final int activities;
  final int remaining;
  final int? facesTooSmall;
  final Map<String, dynamic>? sceneGates;

  const PhotoAiAnalyzeResponse({
    required this.processed,
    required this.skipped,
    required this.faces,
    required this.scenes,
    required this.ocr,
    required this.activities,
    required this.remaining,
    this.facesTooSmall,
    this.sceneGates,
  });

  factory PhotoAiAnalyzeResponse.fromJson(Map<String, dynamic> json) => PhotoAiAnalyzeResponse(
        processed: json['processed'] as int,
        skipped: json['skipped'] as int,
        faces: json['faces'] as int,
        scenes: json['scenes'] as int,
        ocr: json['ocr'] as int,
        activities: json['activities'] as int,
        remaining: json['remaining'] as int,
        facesTooSmall: json['facesTooSmall'] == null ? null : json['facesTooSmall'] as int,
        sceneGates: json['sceneGates'] == null ? null : json['sceneGates'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'processed': processed,
        'skipped': skipped,
        'faces': faces,
        'scenes': scenes,
        'ocr': ocr,
        'activities': activities,
        'remaining': remaining,
        if (facesTooSmall != null) 'facesTooSmall': facesTooSmall!,
        if (sceneGates != null) 'sceneGates': sceneGates!,
      };
}

class PhotoFaceClusterItem {
  final String id;
  final String? name;
  final int size;
  final String? coverPhotoId;
  final String? coverFaceId;

  const PhotoFaceClusterItem({
    required this.id,
    required this.name,
    required this.size,
    required this.coverPhotoId,
    this.coverFaceId,
  });

  factory PhotoFaceClusterItem.fromJson(Map<String, dynamic> json) => PhotoFaceClusterItem(
        id: json['id'] as String,
        name: json['name'] as String?,
        size: json['size'] as int,
        coverPhotoId: json['coverPhotoId'] as String?,
        coverFaceId: json['coverFaceId'] == null ? null : json['coverFaceId'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'size': size,
        'coverPhotoId': coverPhotoId,
        if (coverFaceId != null) 'coverFaceId': coverFaceId!,
      };
}

class PhotoFaceClusterList {
  final List<PhotoFaceClusterItem> items;

  const PhotoFaceClusterList({
    required this.items,
  });

  factory PhotoFaceClusterList.fromJson(Map<String, dynamic> json) => PhotoFaceClusterList(
        items: (json['items'] as List<dynamic>).map((e) => PhotoFaceClusterItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoFaceItem {
  final String id;
  final String photoId;
  final String path;
  final int takenAt;
  final double score;
  final int? boxLeft;
  final int? boxTop;
  final int? boxWidth;
  final int? boxHeight;

  const PhotoFaceItem({
    required this.id,
    required this.photoId,
    required this.path,
    required this.takenAt,
    required this.score,
    this.boxLeft,
    this.boxTop,
    this.boxWidth,
    this.boxHeight,
  });

  factory PhotoFaceItem.fromJson(Map<String, dynamic> json) => PhotoFaceItem(
        id: json['id'] as String,
        photoId: json['photoId'] as String,
        path: json['path'] as String,
        takenAt: json['takenAt'] as int,
        score: (json['score'] as num).toDouble(),
        boxLeft: json['boxLeft'] == null ? null : json['boxLeft'] as int?,
        boxTop: json['boxTop'] == null ? null : json['boxTop'] as int?,
        boxWidth: json['boxWidth'] == null ? null : json['boxWidth'] as int?,
        boxHeight: json['boxHeight'] == null ? null : json['boxHeight'] as int?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'photoId': photoId,
        'path': path,
        'takenAt': takenAt,
        'score': score,
        if (boxLeft != null) 'boxLeft': boxLeft!,
        if (boxTop != null) 'boxTop': boxTop!,
        if (boxWidth != null) 'boxWidth': boxWidth!,
        if (boxHeight != null) 'boxHeight': boxHeight!,
      };
}

class PhotoFaceBackfillBody {
  final int? limit;
  final List<String>? photoIds;

  const PhotoFaceBackfillBody({
    this.limit,
    this.photoIds,
  });

  factory PhotoFaceBackfillBody.fromJson(Map<String, dynamic> json) => PhotoFaceBackfillBody(
        limit: json['limit'] == null ? null : json['limit'] as int,
        photoIds: json['photoIds'] == null ? null : (json['photoIds'] as List<dynamic>).cast<String>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (limit != null) 'limit': limit!,
        if (photoIds != null) 'photoIds': photoIds!,
      };
}

class PhotoFaceBackfillResponse {
  final int photos;
  final int faces;
  final int facesTooSmall;
  final int remaining;
  final int skipped;

  const PhotoFaceBackfillResponse({
    required this.photos,
    required this.faces,
    required this.facesTooSmall,
    required this.remaining,
    required this.skipped,
  });

  factory PhotoFaceBackfillResponse.fromJson(Map<String, dynamic> json) => PhotoFaceBackfillResponse(
        photos: json['photos'] as int,
        faces: json['faces'] as int,
        facesTooSmall: json['facesTooSmall'] as int,
        remaining: json['remaining'] as int,
        skipped: json['skipped'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'photos': photos,
        'faces': faces,
        'facesTooSmall': facesTooSmall,
        'remaining': remaining,
        'skipped': skipped,
      };
}

class PhotoFaceList {
  final List<PhotoFaceItem> items;

  const PhotoFaceList({
    required this.items,
  });

  factory PhotoFaceList.fromJson(Map<String, dynamic> json) => PhotoFaceList(
        items: (json['items'] as List<dynamic>).map((e) => PhotoFaceItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoSceneSummaryItem {
  final String label;
  final int count;
  final String? coverId;
  final String? coverPath;

  const PhotoSceneSummaryItem({
    required this.label,
    required this.count,
    this.coverId,
    this.coverPath,
  });

  factory PhotoSceneSummaryItem.fromJson(Map<String, dynamic> json) => PhotoSceneSummaryItem(
        label: json['label'] as String,
        count: json['count'] as int,
        coverId: json['coverId'] == null ? null : json['coverId'] as String?,
        coverPath: json['coverPath'] == null ? null : json['coverPath'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'label': label,
        'count': count,
        if (coverId != null) 'coverId': coverId!,
        if (coverPath != null) 'coverPath': coverPath!,
      };
}

class PhotoSceneSummary {
  final List<PhotoSceneSummaryItem> items;

  const PhotoSceneSummary({
    required this.items,
  });

  factory PhotoSceneSummary.fromJson(Map<String, dynamic> json) => PhotoSceneSummary(
        items: (json['items'] as List<dynamic>).map((e) => PhotoSceneSummaryItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoSceneTagSummaryItem {
  final String label;
  final int count;
  final int confident;
  final int ambiguous;
  final String? coverId;
  final String? coverPath;

  const PhotoSceneTagSummaryItem({
    required this.label,
    required this.count,
    required this.confident,
    required this.ambiguous,
    required this.coverId,
    required this.coverPath,
  });

  factory PhotoSceneTagSummaryItem.fromJson(Map<String, dynamic> json) => PhotoSceneTagSummaryItem(
        label: json['label'] as String,
        count: json['count'] as int,
        confident: json['confident'] as int,
        ambiguous: json['ambiguous'] as int,
        coverId: json['coverId'] as String?,
        coverPath: json['coverPath'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'label': label,
        'count': count,
        'confident': confident,
        'ambiguous': ambiguous,
        'coverId': coverId,
        'coverPath': coverPath,
      };
}

class PhotoSceneTagSummary {
  final List<PhotoSceneTagSummaryItem> items;

  const PhotoSceneTagSummary({
    required this.items,
  });

  factory PhotoSceneTagSummary.fromJson(Map<String, dynamic> json) => PhotoSceneTagSummary(
        items: (json['items'] as List<dynamic>).map((e) => PhotoSceneTagSummaryItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoSceneTagItem {
  final String id;
  final String path;
  final int takenAt;
  final double score;
  final String? gate;
  final String? label;

  const PhotoSceneTagItem({
    required this.id,
    required this.path,
    required this.takenAt,
    required this.score,
    required this.gate,
    this.label,
  });

  factory PhotoSceneTagItem.fromJson(Map<String, dynamic> json) => PhotoSceneTagItem(
        id: json['id'] as String,
        path: json['path'] as String,
        takenAt: json['takenAt'] as int,
        score: (json['score'] as num).toDouble(),
        gate: json['gate'] as String?,
        label: json['label'] == null ? null : json['label'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'path': path,
        'takenAt': takenAt,
        'score': score,
        'gate': gate,
        if (label != null) 'label': label!,
      };
}

class PhotoSceneTagList {
  final String label;
  final List<PhotoSceneTagItem> items;

  const PhotoSceneTagList({
    required this.label,
    required this.items,
  });

  factory PhotoSceneTagList.fromJson(Map<String, dynamic> json) => PhotoSceneTagList(
        label: json['label'] as String,
        items: (json['items'] as List<dynamic>).map((e) => PhotoSceneTagItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'label': label,
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoAiPhotoRef {
  final String id;
  final String path;
  final int takenAt;
  final double? score;

  const PhotoAiPhotoRef({
    required this.id,
    required this.path,
    required this.takenAt,
    this.score,
  });

  factory PhotoAiPhotoRef.fromJson(Map<String, dynamic> json) => PhotoAiPhotoRef(
        id: json['id'] as String,
        path: json['path'] as String,
        takenAt: json['takenAt'] as int,
        score: json['score'] == null ? null : (json['score'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'path': path,
        'takenAt': takenAt,
        if (score != null) 'score': score!,
      };
}

class PhotoAiPhotoRefList {
  final List<PhotoAiPhotoRef> items;

  const PhotoAiPhotoRefList({
    required this.items,
  });

  factory PhotoAiPhotoRefList.fromJson(Map<String, dynamic> json) => PhotoAiPhotoRefList(
        items: (json['items'] as List<dynamic>).map((e) => PhotoAiPhotoRef.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoAiBatchBody {
  final String? libraryId;
  final int? limit;
  final bool? force;

  const PhotoAiBatchBody({
    this.libraryId,
    this.limit,
    this.force,
  });

  factory PhotoAiBatchBody.fromJson(Map<String, dynamic> json) => PhotoAiBatchBody(
        libraryId: json['libraryId'] == null ? null : json['libraryId'] as String,
        limit: json['limit'] == null ? null : json['limit'] as int,
        force: json['force'] == null ? null : json['force'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (libraryId != null) 'libraryId': libraryId!,
        if (limit != null) 'limit': limit!,
        if (force != null) 'force': force!,
      };
}

class PhotoSemanticComponent {
  final String key;
  final String binding;
  final String tag;
  final String via;

  const PhotoSemanticComponent({
    required this.key,
    required this.binding,
    required this.tag,
    required this.via,
  });

  factory PhotoSemanticComponent.fromJson(Map<String, dynamic> json) => PhotoSemanticComponent(
        key: json['key'] as String,
        binding: json['binding'] as String,
        tag: json['tag'] as String,
        via: json['via'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'binding': binding,
        'tag': tag,
        'via': via,
      };
}

class PhotoSemanticTag {
  final String label;
  final double score;
  final int hits;

  const PhotoSemanticTag({
    required this.label,
    required this.score,
    required this.hits,
  });

  factory PhotoSemanticTag.fromJson(Map<String, dynamic> json) => PhotoSemanticTag(
        label: json['label'] as String,
        score: (json['score'] as num).toDouble(),
        hits: json['hits'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'label': label,
        'score': score,
        'hits': hits,
      };
}

class PhotoSemanticParse {
  final bool ok;
  final String normalized;
  final List<PhotoSemanticComponent> components;
  final List<String> unmatched;
  final List<PhotoSemanticTag> tags;
  final String? reason;

  const PhotoSemanticParse({
    required this.ok,
    required this.normalized,
    required this.components,
    required this.unmatched,
    required this.tags,
    this.reason,
  });

  factory PhotoSemanticParse.fromJson(Map<String, dynamic> json) => PhotoSemanticParse(
        ok: json['ok'] as bool,
        normalized: json['normalized'] as String,
        components: (json['components'] as List<dynamic>).map((e) => PhotoSemanticComponent.fromJson(e as Map<String, dynamic>)).toList(),
        unmatched: (json['unmatched'] as List<dynamic>).cast<String>(),
        tags: (json['tags'] as List<dynamic>).map((e) => PhotoSemanticTag.fromJson(e as Map<String, dynamic>)).toList(),
        reason: json['reason'] == null ? null : json['reason'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        'normalized': normalized,
        'components': components.map((e) => e.toJson()).toList(),
        'unmatched': unmatched,
        'tags': tags.map((e) => e.toJson()).toList(),
        if (reason != null) 'reason': reason!,
      };
}

class PhotoSemanticHit {
  final String id;
  final String path;
  final int takenAt;
  final double score;
  final List<String> matched;

  const PhotoSemanticHit({
    required this.id,
    required this.path,
    required this.takenAt,
    required this.score,
    required this.matched,
  });

  factory PhotoSemanticHit.fromJson(Map<String, dynamic> json) => PhotoSemanticHit(
        id: json['id'] as String,
        path: json['path'] as String,
        takenAt: json['takenAt'] as int,
        score: (json['score'] as num).toDouble(),
        matched: (json['matched'] as List<dynamic>).cast<String>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'path': path,
        'takenAt': takenAt,
        'score': score,
        'matched': matched,
      };
}

class PhotoSemanticSearchResponse {
  final String normalized;
  final List<PhotoSemanticTag> tags;
  final List<String> unmatched;
  final List<PhotoSemanticHit> items;
  final bool degraded;
  final String reason;

  const PhotoSemanticSearchResponse({
    required this.normalized,
    required this.tags,
    required this.unmatched,
    required this.items,
    required this.degraded,
    required this.reason,
  });

  factory PhotoSemanticSearchResponse.fromJson(Map<String, dynamic> json) => PhotoSemanticSearchResponse(
        normalized: json['normalized'] as String,
        tags: (json['tags'] as List<dynamic>).map((e) => PhotoSemanticTag.fromJson(e as Map<String, dynamic>)).toList(),
        unmatched: (json['unmatched'] as List<dynamic>).cast<String>(),
        items: (json['items'] as List<dynamic>).map((e) => PhotoSemanticHit.fromJson(e as Map<String, dynamic>)).toList(),
        degraded: json['degraded'] as bool,
        reason: json['reason'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'normalized': normalized,
        'tags': tags.map((e) => e.toJson()).toList(),
        'unmatched': unmatched,
        'items': items.map((e) => e.toJson()).toList(),
        'degraded': degraded,
        'reason': reason,
      };
}

class PhotoFaceClusterFilter {
  final int? minCount;

  const PhotoFaceClusterFilter({
    this.minCount,
  });

  factory PhotoFaceClusterFilter.fromJson(Map<String, dynamic> json) => PhotoFaceClusterFilter(
        minCount: json['minCount'] == null ? null : json['minCount'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (minCount != null) 'minCount': minCount!,
      };
}

class PhotoFaceNameBody {
  final String clusterId;
  final String name;

  const PhotoFaceNameBody({
    required this.clusterId,
    required this.name,
  });

  factory PhotoFaceNameBody.fromJson(Map<String, dynamic> json) => PhotoFaceNameBody(
        clusterId: json['clusterId'] as String,
        name: json['name'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'clusterId': clusterId,
        'name': name,
      };
}

class PhotoFaceDissolveBody {
  final String clusterId;

  const PhotoFaceDissolveBody({
    required this.clusterId,
  });

  factory PhotoFaceDissolveBody.fromJson(Map<String, dynamic> json) => PhotoFaceDissolveBody(
        clusterId: json['clusterId'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'clusterId': clusterId,
      };
}

class PhotoFaceMergeBody {
  final String fromId;
  final String toId;

  const PhotoFaceMergeBody({
    required this.fromId,
    required this.toId,
  });

  factory PhotoFaceMergeBody.fromJson(Map<String, dynamic> json) => PhotoFaceMergeBody(
        fromId: json['fromId'] as String,
        toId: json['toId'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'fromId': fromId,
        'toId': toId,
      };
}

class PhotoFaceMergeResponse {
  final int moved;
  final String clusterId;

  const PhotoFaceMergeResponse({
    required this.moved,
    required this.clusterId,
  });

  factory PhotoFaceMergeResponse.fromJson(Map<String, dynamic> json) => PhotoFaceMergeResponse(
        moved: json['moved'] as int,
        clusterId: json['clusterId'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'moved': moved,
        'clusterId': clusterId,
      };
}

class PhotoFaceMoveBody {
  final String faceId;
  final String? toClusterId;

  const PhotoFaceMoveBody({
    required this.faceId,
    this.toClusterId,
  });

  factory PhotoFaceMoveBody.fromJson(Map<String, dynamic> json) => PhotoFaceMoveBody(
        faceId: json['faceId'] as String,
        toClusterId: json['toClusterId'] == null ? null : json['toClusterId'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'faceId': faceId,
        if (toClusterId != null) 'toClusterId': toClusterId!,
      };
}

class PhotoFaceMoveResponse {
  final bool ok;
  final String? clusterId;

  const PhotoFaceMoveResponse({
    required this.ok,
    required this.clusterId,
  });

  factory PhotoFaceMoveResponse.fromJson(Map<String, dynamic> json) => PhotoFaceMoveResponse(
        ok: json['ok'] as bool,
        clusterId: json['clusterId'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        'clusterId': clusterId,
      };
}

class PhotoFaceMergeCandidateBody {
  final double? minSim;
  final int? minEvidence;
  final int? limit;

  const PhotoFaceMergeCandidateBody({
    this.minSim,
    this.minEvidence,
    this.limit,
  });

  factory PhotoFaceMergeCandidateBody.fromJson(Map<String, dynamic> json) => PhotoFaceMergeCandidateBody(
        minSim: json['minSim'] == null ? null : (json['minSim'] as num).toDouble(),
        minEvidence: json['minEvidence'] == null ? null : json['minEvidence'] as int,
        limit: json['limit'] == null ? null : json['limit'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (minSim != null) 'minSim': minSim!,
        if (minEvidence != null) 'minEvidence': minEvidence!,
        if (limit != null) 'limit': limit!,
      };
}

class PhotoFaceMergeCandidate {
  final String fromId;
  final String toId;
  final String? fromName;
  final String? toName;
  final int fromSize;
  final int toSize;
  final String? fromCoverFaceId;
  final String? toCoverFaceId;
  final double sim;
  final int evidence;

  const PhotoFaceMergeCandidate({
    required this.fromId,
    required this.toId,
    required this.fromName,
    required this.toName,
    required this.fromSize,
    required this.toSize,
    required this.fromCoverFaceId,
    required this.toCoverFaceId,
    required this.sim,
    required this.evidence,
  });

  factory PhotoFaceMergeCandidate.fromJson(Map<String, dynamic> json) => PhotoFaceMergeCandidate(
        fromId: json['fromId'] as String,
        toId: json['toId'] as String,
        fromName: json['fromName'] as String?,
        toName: json['toName'] as String?,
        fromSize: json['fromSize'] as int,
        toSize: json['toSize'] as int,
        fromCoverFaceId: json['fromCoverFaceId'] as String?,
        toCoverFaceId: json['toCoverFaceId'] as String?,
        sim: (json['sim'] as num).toDouble(),
        evidence: json['evidence'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'fromId': fromId,
        'toId': toId,
        'fromName': fromName,
        'toName': toName,
        'fromSize': fromSize,
        'toSize': toSize,
        'fromCoverFaceId': fromCoverFaceId,
        'toCoverFaceId': toCoverFaceId,
        'sim': sim,
        'evidence': evidence,
      };
}

class PhotoFaceMergeCandidateList {
  final List<PhotoFaceMergeCandidate> items;
  final int scanned;
  final int pairs;

  const PhotoFaceMergeCandidateList({
    required this.items,
    required this.scanned,
    required this.pairs,
  });

  factory PhotoFaceMergeCandidateList.fromJson(Map<String, dynamic> json) => PhotoFaceMergeCandidateList(
        items: (json['items'] as List<dynamic>).map((e) => PhotoFaceMergeCandidate.fromJson(e as Map<String, dynamic>)).toList(),
        scanned: json['scanned'] as int,
        pairs: json['pairs'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
        'scanned': scanned,
        'pairs': pairs,
      };
}

class PhotoFaceMergeUndoBody {
  final List<String>? ids;
  final int? limit;

  const PhotoFaceMergeUndoBody({
    this.ids,
    this.limit,
  });

  factory PhotoFaceMergeUndoBody.fromJson(Map<String, dynamic> json) => PhotoFaceMergeUndoBody(
        ids: json['ids'] == null ? null : (json['ids'] as List<dynamic>).cast<String>(),
        limit: json['limit'] == null ? null : json['limit'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (ids != null) 'ids': ids!,
        if (limit != null) 'limit': limit!,
      };
}

class PhotoFaceMergeUndoResponse {
  final int restored;
  final int faces;

  const PhotoFaceMergeUndoResponse({
    required this.restored,
    required this.faces,
  });

  factory PhotoFaceMergeUndoResponse.fromJson(Map<String, dynamic> json) => PhotoFaceMergeUndoResponse(
        restored: json['restored'] as int,
        faces: json['faces'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'restored': restored,
        'faces': faces,
      };
}

class PhotoFaceRebuildBody {
  final int? limit;

  const PhotoFaceRebuildBody({
    this.limit,
  });

  factory PhotoFaceRebuildBody.fromJson(Map<String, dynamic> json) => PhotoFaceRebuildBody(
        limit: json['limit'] == null ? null : json['limit'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (limit != null) 'limit': limit!,
      };
}

class PhotoFaceRebuildResponse {
  final String runId;
  final int faces;
  final int clusters;
  final int ms;
  final double? coverage;
  final int? elapsedMs;
  final String? algoVersion;

  const PhotoFaceRebuildResponse({
    required this.runId,
    required this.faces,
    required this.clusters,
    required this.ms,
    this.coverage,
    this.elapsedMs,
    this.algoVersion,
  });

  factory PhotoFaceRebuildResponse.fromJson(Map<String, dynamic> json) => PhotoFaceRebuildResponse(
        runId: json['runId'] as String,
        faces: json['faces'] as int,
        clusters: json['clusters'] as int,
        ms: json['ms'] as int,
        coverage: json['coverage'] == null ? null : (json['coverage'] as num).toDouble(),
        elapsedMs: json['elapsedMs'] == null ? null : json['elapsedMs'] as int,
        algoVersion: json['algoVersion'] == null ? null : json['algoVersion'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'runId': runId,
        'faces': faces,
        'clusters': clusters,
        'ms': ms,
        if (coverage != null) 'coverage': coverage!,
        if (elapsedMs != null) 'elapsedMs': elapsedMs!,
        if (algoVersion != null) 'algoVersion': algoVersion!,
      };
}

class PhotoFaceRollbackBody {
  final String runId;

  const PhotoFaceRollbackBody({
    required this.runId,
  });

  factory PhotoFaceRollbackBody.fromJson(Map<String, dynamic> json) => PhotoFaceRollbackBody(
        runId: json['runId'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'runId': runId,
      };
}

class PhotoFaceOk {
  final bool ok;

  const PhotoFaceOk({
    required this.ok,
  });

  factory PhotoFaceOk.fromJson(Map<String, dynamic> json) => PhotoFaceOk(
        ok: json['ok'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
      };
}

class PhotoFaceRescanBody {
  final int? limit;

  const PhotoFaceRescanBody({
    this.limit,
  });

  factory PhotoFaceRescanBody.fromJson(Map<String, dynamic> json) => PhotoFaceRescanBody(
        limit: json['limit'] == null ? null : json['limit'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (limit != null) 'limit': limit!,
      };
}

class PhotoFaceMergeSimilarBody {
  final bool? dryRun;
  final int? rounds;

  const PhotoFaceMergeSimilarBody({
    this.dryRun,
    this.rounds,
  });

  factory PhotoFaceMergeSimilarBody.fromJson(Map<String, dynamic> json) => PhotoFaceMergeSimilarBody(
        dryRun: json['dryRun'] == null ? null : json['dryRun'] as bool,
        rounds: json['rounds'] == null ? null : json['rounds'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (dryRun != null) 'dryRun': dryRun!,
        if (rounds != null) 'rounds': rounds!,
      };
}

class PhotoAiError {
  final String error;
  final String? message;
  final String? code;
  final String? traceId;
  final Map<String, dynamic>? details;

  const PhotoAiError({
    required this.error,
    this.message,
    this.code,
    this.traceId,
    this.details,
  });

  factory PhotoAiError.fromJson(Map<String, dynamic> json) => PhotoAiError(
        error: json['error'] as String,
        message: json['message'] == null ? null : json['message'] as String,
        code: json['code'] == null ? null : json['code'] as String,
        traceId: json['traceId'] == null ? null : json['traceId'] as String,
        details: json['details'] == null ? null : json['details'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'error': error,
        if (message != null) 'message': message!,
        if (code != null) 'code': code!,
        if (traceId != null) 'traceId': traceId!,
        if (details != null) 'details': details!,
      };
}

class PhotoMapMarker {
  final String id;
  final String path;
  final double latitude;
  final double longitude;
  final int takenAt;
  final int photoCount;
  final String geohash;
  final String cellKey;
  final int cellPrecision;

  const PhotoMapMarker({
    required this.id,
    required this.path,
    required this.latitude,
    required this.longitude,
    required this.takenAt,
    required this.photoCount,
    required this.geohash,
    required this.cellKey,
    required this.cellPrecision,
  });

  factory PhotoMapMarker.fromJson(Map<String, dynamic> json) => PhotoMapMarker(
        id: json['id'] as String,
        path: json['path'] as String,
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        takenAt: json['takenAt'] as int,
        photoCount: json['photoCount'] as int,
        geohash: json['geohash'] as String,
        cellKey: json['cellKey'] as String,
        cellPrecision: json['cellPrecision'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'path': path,
        'latitude': latitude,
        'longitude': longitude,
        'takenAt': takenAt,
        'photoCount': photoCount,
        'geohash': geohash,
        'cellKey': cellKey,
        'cellPrecision': cellPrecision,
      };
}

class PhotoMapBoundsResponse {
  final int precision;
  final int cells;
  final List<PhotoMapMarker> items;

  const PhotoMapBoundsResponse({
    required this.precision,
    required this.cells,
    required this.items,
  });

  factory PhotoMapBoundsResponse.fromJson(Map<String, dynamic> json) => PhotoMapBoundsResponse(
        precision: json['precision'] as int,
        cells: json['cells'] as int,
        items: (json['items'] as List<dynamic>).map((e) => PhotoMapMarker.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'precision': precision,
        'cells': cells,
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoMapPhoto {
  final String id;
  final String path;
  final int takenAt;
  final double? latitude;
  final double? longitude;
  final String? geohash;

  const PhotoMapPhoto({
    required this.id,
    required this.path,
    required this.takenAt,
    required this.latitude,
    required this.longitude,
    required this.geohash,
  });

  factory PhotoMapPhoto.fromJson(Map<String, dynamic> json) => PhotoMapPhoto(
        id: json['id'] as String,
        path: json['path'] as String,
        takenAt: json['takenAt'] as int,
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
        geohash: json['geohash'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'path': path,
        'takenAt': takenAt,
        'latitude': latitude,
        'longitude': longitude,
        'geohash': geohash,
      };
}

class PhotoMapCellsResponse {
  final int total;
  final List<PhotoMapPhoto> items;
  final String? nextCursor;

  const PhotoMapCellsResponse({
    required this.total,
    required this.items,
    required this.nextCursor,
  });

  factory PhotoMapCellsResponse.fromJson(Map<String, dynamic> json) => PhotoMapCellsResponse(
        total: json['total'] as int,
        items: (json['items'] as List<dynamic>).map((e) => PhotoMapPhoto.fromJson(e as Map<String, dynamic>)).toList(),
        nextCursor: json['nextCursor'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'total': total,
        'items': items.map((e) => e.toJson()).toList(),
        'nextCursor': nextCursor,
      };
}

class PhotoMapPlaceResponse {
  final String name;
  final bool available;

  const PhotoMapPlaceResponse({
    required this.name,
    required this.available,
  });

  factory PhotoMapPlaceResponse.fromJson(Map<String, dynamic> json) => PhotoMapPlaceResponse(
        name: json['name'] as String,
        available: json['available'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'available': available,
      };
}

class PhotoMapTileServer {
  final String id;
  final String name;
  final String url;
  final String coordinate;
  final int maxLevel;
  final bool isDefault;
  final bool isCurrent;

  const PhotoMapTileServer({
    required this.id,
    required this.name,
    required this.url,
    required this.coordinate,
    required this.maxLevel,
    required this.isDefault,
    required this.isCurrent,
  });

  factory PhotoMapTileServer.fromJson(Map<String, dynamic> json) => PhotoMapTileServer(
        id: json['id'] as String,
        name: json['name'] as String,
        url: json['url'] as String,
        coordinate: json['coordinate'] as String,
        maxLevel: json['maxLevel'] as int,
        isDefault: json['isDefault'] as bool,
        isCurrent: json['isCurrent'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'url': url,
        'coordinate': coordinate,
        'maxLevel': maxLevel,
        'isDefault': isDefault,
        'isCurrent': isCurrent,
      };
}

class PhotoMapTileServerList {
  final List<PhotoMapTileServer> items;

  const PhotoMapTileServerList({
    required this.items,
  });

  factory PhotoMapTileServerList.fromJson(Map<String, dynamic> json) => PhotoMapTileServerList(
        items: (json['items'] as List<dynamic>).map((e) => PhotoMapTileServer.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoMapTileServerBody {
  final String? id;
  final String? name;
  final String? url;
  final String? coordinate;
  final int? maxLevel;

  const PhotoMapTileServerBody({
    this.id,
    this.name,
    this.url,
    this.coordinate,
    this.maxLevel,
  });

  factory PhotoMapTileServerBody.fromJson(Map<String, dynamic> json) => PhotoMapTileServerBody(
        id: json['id'] == null ? null : json['id'] as String,
        name: json['name'] == null ? null : json['name'] as String,
        url: json['url'] == null ? null : json['url'] as String,
        coordinate: json['coordinate'] == null ? null : json['coordinate'] as String,
        maxLevel: json['maxLevel'] == null ? null : json['maxLevel'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (id != null) 'id': id!,
        if (name != null) 'name': name!,
        if (url != null) 'url': url!,
        if (coordinate != null) 'coordinate': coordinate!,
        if (maxLevel != null) 'maxLevel': maxLevel!,
      };
}

class PhotoMapJourneyPoint {
  final String id;
  final String path;
  final double latitude;
  final double longitude;
  final int takenAt;

  const PhotoMapJourneyPoint({
    required this.id,
    required this.path,
    required this.latitude,
    required this.longitude,
    required this.takenAt,
  });

  factory PhotoMapJourneyPoint.fromJson(Map<String, dynamic> json) => PhotoMapJourneyPoint(
        id: json['id'] as String,
        path: json['path'] as String,
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        takenAt: json['takenAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'path': path,
        'latitude': latitude,
        'longitude': longitude,
        'takenAt': takenAt,
      };
}

class PhotoMapJourneySegment {
  final int startAt;
  final int endAt;
  final double distanceKm;
  final List<PhotoMapJourneyPoint> points;

  const PhotoMapJourneySegment({
    required this.startAt,
    required this.endAt,
    required this.distanceKm,
    required this.points,
  });

  factory PhotoMapJourneySegment.fromJson(Map<String, dynamic> json) => PhotoMapJourneySegment(
        startAt: json['startAt'] as int,
        endAt: json['endAt'] as int,
        distanceKm: (json['distanceKm'] as num).toDouble(),
        points: (json['points'] as List<dynamic>).map((e) => PhotoMapJourneyPoint.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'startAt': startAt,
        'endAt': endAt,
        'distanceKm': distanceKm,
        'points': points.map((e) => e.toJson()).toList(),
      };
}

class PhotoMapJourneyResponse {
  final List<PhotoMapJourneySegment> segments;
  final int points;
  final double distanceKm;
  final int days;

  const PhotoMapJourneyResponse({
    required this.segments,
    required this.points,
    required this.distanceKm,
    required this.days,
  });

  factory PhotoMapJourneyResponse.fromJson(Map<String, dynamic> json) => PhotoMapJourneyResponse(
        segments: (json['segments'] as List<dynamic>).map((e) => PhotoMapJourneySegment.fromJson(e as Map<String, dynamic>)).toList(),
        points: json['points'] as int,
        distanceKm: (json['distanceKm'] as num).toDouble(),
        days: json['days'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'segments': segments.map((e) => e.toJson()).toList(),
        'points': points,
        'distanceKm': distanceKm,
        'days': days,
      };
}

class PhotoMapError {
  final String error;
  final String? message;
  final String? code;
  final String? traceId;
  final Map<String, dynamic>? details;

  const PhotoMapError({
    required this.error,
    this.message,
    this.code,
    this.traceId,
    this.details,
  });

  factory PhotoMapError.fromJson(Map<String, dynamic> json) => PhotoMapError(
        error: json['error'] as String,
        message: json['message'] == null ? null : json['message'] as String,
        code: json['code'] == null ? null : json['code'] as String,
        traceId: json['traceId'] == null ? null : json['traceId'] as String,
        details: json['details'] == null ? null : json['details'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'error': error,
        if (message != null) 'message': message!,
        if (code != null) 'code': code!,
        if (traceId != null) 'traceId': traceId!,
        if (details != null) 'details': details!,
      };
}

class PhotoCleanupItem {
  final String id;
  final String path;
  final int takenAt;
  final int size;
  final bool absent;

  const PhotoCleanupItem({
    required this.id,
    required this.path,
    required this.takenAt,
    required this.size,
    required this.absent,
  });

  factory PhotoCleanupItem.fromJson(Map<String, dynamic> json) => PhotoCleanupItem(
        id: json['id'] as String,
        path: json['path'] as String,
        takenAt: json['takenAt'] as int,
        size: json['size'] as int,
        absent: json['absent'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'path': path,
        'takenAt': takenAt,
        'size': size,
        'absent': absent,
      };
}

class PhotoCleanupGroup {
  final String key;
  final String kind;
  final int count;
  final int bytesEach;
  final int wastedBytes;
  final String keepId;
  final List<String> ids;
  final List<PhotoCleanupItem> items;

  const PhotoCleanupGroup({
    required this.key,
    required this.kind,
    required this.count,
    required this.bytesEach,
    required this.wastedBytes,
    required this.keepId,
    required this.ids,
    required this.items,
  });

  factory PhotoCleanupGroup.fromJson(Map<String, dynamic> json) => PhotoCleanupGroup(
        key: json['key'] as String,
        kind: json['kind'] as String,
        count: json['count'] as int,
        bytesEach: json['bytesEach'] as int,
        wastedBytes: json['wastedBytes'] as int,
        keepId: json['keepId'] as String,
        ids: (json['ids'] as List<dynamic>).cast<String>(),
        items: (json['items'] as List<dynamic>).map((e) => PhotoCleanupItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'kind': kind,
        'count': count,
        'bytesEach': bytesEach,
        'wastedBytes': wastedBytes,
        'keepId': keepId,
        'ids': ids,
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoCleanupPreviewBody {
  final int? limit;
  final double? similarity;
  final bool? includeSimilar;

  const PhotoCleanupPreviewBody({
    this.limit,
    this.similarity,
    this.includeSimilar,
  });

  factory PhotoCleanupPreviewBody.fromJson(Map<String, dynamic> json) => PhotoCleanupPreviewBody(
        limit: json['limit'] == null ? null : json['limit'] as int,
        similarity: json['similarity'] == null ? null : (json['similarity'] as num).toDouble(),
        includeSimilar: json['includeSimilar'] == null ? null : json['includeSimilar'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (limit != null) 'limit': limit!,
        if (similarity != null) 'similarity': similarity!,
        if (includeSimilar != null) 'includeSimilar': includeSimilar!,
      };
}

class PhotoCleanupPreviewResponse {
  final Map<String, dynamic> duplicate;
  final Map<String, dynamic> nameDuplicate;
  final Map<String, dynamic> similar;
  final int missingMd5;
  final int md5Candidates;

  const PhotoCleanupPreviewResponse({
    required this.duplicate,
    required this.nameDuplicate,
    required this.similar,
    required this.missingMd5,
    required this.md5Candidates,
  });

  factory PhotoCleanupPreviewResponse.fromJson(Map<String, dynamic> json) => PhotoCleanupPreviewResponse(
        duplicate: json['duplicate'] as Map<String, dynamic>,
        nameDuplicate: json['nameDuplicate'] as Map<String, dynamic>,
        similar: json['similar'] as Map<String, dynamic>,
        missingMd5: json['missingMd5'] as int,
        md5Candidates: json['md5Candidates'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'duplicate': duplicate,
        'nameDuplicate': nameDuplicate,
        'similar': similar,
        'missingMd5': missingMd5,
        'md5Candidates': md5Candidates,
      };
}

class PhotoCleanupApplyGroup {
  final String? key;
  final String keepId;
  final List<String> removeIds;

  const PhotoCleanupApplyGroup({
    this.key,
    required this.keepId,
    required this.removeIds,
  });

  factory PhotoCleanupApplyGroup.fromJson(Map<String, dynamic> json) => PhotoCleanupApplyGroup(
        key: json['key'] == null ? null : json['key'] as String,
        keepId: json['keepId'] as String,
        removeIds: (json['removeIds'] as List<dynamic>).cast<String>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (key != null) 'key': key!,
        'keepId': keepId,
        'removeIds': removeIds,
      };
}

class PhotoCleanupApplyBody {
  final String kind;
  final List<PhotoCleanupApplyGroup> groups;

  const PhotoCleanupApplyBody({
    required this.kind,
    required this.groups,
  });

  factory PhotoCleanupApplyBody.fromJson(Map<String, dynamic> json) => PhotoCleanupApplyBody(
        kind: json['kind'] as String,
        groups: (json['groups'] as List<dynamic>).map((e) => PhotoCleanupApplyGroup.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
        'groups': groups.map((e) => e.toJson()).toList(),
      };
}

class PhotoCleanupApplyResponse {
  final String batchId;
  final int trashed;
  final int merged;

  const PhotoCleanupApplyResponse({
    required this.batchId,
    required this.trashed,
    required this.merged,
  });

  factory PhotoCleanupApplyResponse.fromJson(Map<String, dynamic> json) => PhotoCleanupApplyResponse(
        batchId: json['batchId'] as String,
        trashed: json['trashed'] as int,
        merged: json['merged'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'batchId': batchId,
        'trashed': trashed,
        'merged': merged,
      };
}

class PhotoCleanupUndoBody {
  final String batchId;

  const PhotoCleanupUndoBody({
    required this.batchId,
  });

  factory PhotoCleanupUndoBody.fromJson(Map<String, dynamic> json) => PhotoCleanupUndoBody(
        batchId: json['batchId'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'batchId': batchId,
      };
}

class PhotoCleanupUndoResponse {
  final int restored;
  final String batchId;

  const PhotoCleanupUndoResponse({
    required this.restored,
    required this.batchId,
  });

  factory PhotoCleanupUndoResponse.fromJson(Map<String, dynamic> json) => PhotoCleanupUndoResponse(
        restored: json['restored'] as int,
        batchId: json['batchId'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'restored': restored,
        'batchId': batchId,
      };
}

class PhotoCleanupBatch {
  final String id;
  final String kind;
  final int createdAt;
  final int? undoneAt;
  final String summary;

  const PhotoCleanupBatch({
    required this.id,
    required this.kind,
    required this.createdAt,
    required this.undoneAt,
    required this.summary,
  });

  factory PhotoCleanupBatch.fromJson(Map<String, dynamic> json) => PhotoCleanupBatch(
        id: json['id'] as String,
        kind: json['kind'] as String,
        createdAt: json['createdAt'] as int,
        undoneAt: json['undoneAt'] as int?,
        summary: json['summary'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'kind': kind,
        'createdAt': createdAt,
        'undoneAt': undoneAt,
        'summary': summary,
      };
}

class PhotoCleanupBatchList {
  final List<PhotoCleanupBatch> items;

  const PhotoCleanupBatchList({
    required this.items,
  });

  factory PhotoCleanupBatchList.fromJson(Map<String, dynamic> json) => PhotoCleanupBatchList(
        items: (json['items'] as List<dynamic>).map((e) => PhotoCleanupBatch.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoCleanupBackfillBody {
  final int? limit;

  const PhotoCleanupBackfillBody({
    this.limit,
  });

  factory PhotoCleanupBackfillBody.fromJson(Map<String, dynamic> json) => PhotoCleanupBackfillBody(
        limit: json['limit'] == null ? null : json['limit'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (limit != null) 'limit': limit!,
      };
}

class PhotoCleanupBackfillResponse {
  final int candidates;
  final int hashed;
  final int failed;
  final int remaining;

  const PhotoCleanupBackfillResponse({
    required this.candidates,
    required this.hashed,
    required this.failed,
    required this.remaining,
  });

  factory PhotoCleanupBackfillResponse.fromJson(Map<String, dynamic> json) => PhotoCleanupBackfillResponse(
        candidates: json['candidates'] as int,
        hashed: json['hashed'] as int,
        failed: json['failed'] as int,
        remaining: json['remaining'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'candidates': candidates,
        'hashed': hashed,
        'failed': failed,
        'remaining': remaining,
      };
}

class PhotoCleanupOk {
  final bool ok;

  const PhotoCleanupOk({
    required this.ok,
  });

  factory PhotoCleanupOk.fromJson(Map<String, dynamic> json) => PhotoCleanupOk(
        ok: json['ok'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
      };
}

class PhotoCleanupError {
  final String error;
  final String? message;
  final String? code;
  final String? traceId;
  final Map<String, dynamic>? details;

  const PhotoCleanupError({
    required this.error,
    this.message,
    this.code,
    this.traceId,
    this.details,
  });

  factory PhotoCleanupError.fromJson(Map<String, dynamic> json) => PhotoCleanupError(
        error: json['error'] as String,
        message: json['message'] == null ? null : json['message'] as String,
        code: json['code'] == null ? null : json['code'] as String,
        traceId: json['traceId'] == null ? null : json['traceId'] as String,
        details: json['details'] == null ? null : json['details'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'error': error,
        if (message != null) 'message': message!,
        if (code != null) 'code': code!,
        if (traceId != null) 'traceId': traceId!,
        if (details != null) 'details': details!,
      };
}

class PhotoDayFrame {
  final String date;
  final String photoId;
  final String path;
  final int takenAt;
  final double score;
  final String caption;
  final List<String> scenes;
  final List<String> activities;
  final List<String> people;
  final int dayPhotoCount;

  const PhotoDayFrame({
    required this.date,
    required this.photoId,
    required this.path,
    required this.takenAt,
    required this.score,
    required this.caption,
    required this.scenes,
    required this.activities,
    required this.people,
    required this.dayPhotoCount,
  });

  factory PhotoDayFrame.fromJson(Map<String, dynamic> json) => PhotoDayFrame(
        date: json['date'] as String,
        photoId: json['photoId'] as String,
        path: json['path'] as String,
        takenAt: json['takenAt'] as int,
        score: (json['score'] as num).toDouble(),
        caption: json['caption'] as String,
        scenes: (json['scenes'] as List<dynamic>).cast<String>(),
        activities: (json['activities'] as List<dynamic>).cast<String>(),
        people: (json['people'] as List<dynamic>).cast<String>(),
        dayPhotoCount: json['dayPhotoCount'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'date': date,
        'photoId': photoId,
        'path': path,
        'takenAt': takenAt,
        'score': score,
        'caption': caption,
        'scenes': scenes,
        'activities': activities,
        'people': people,
        'dayPhotoCount': dayPhotoCount,
      };
}

class PhotoDayFrameList {
  final List<PhotoDayFrame> items;

  const PhotoDayFrameList({
    required this.items,
  });

  factory PhotoDayFrameList.fromJson(Map<String, dynamic> json) => PhotoDayFrameList(
        items: (json['items'] as List<dynamic>).map((e) => PhotoDayFrame.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PhotoMemoryPick {
  final String id;
  final String path;
  final int takenAt;

  const PhotoMemoryPick({
    required this.id,
    required this.path,
    required this.takenAt,
  });

  factory PhotoMemoryPick.fromJson(Map<String, dynamic> json) => PhotoMemoryPick(
        id: json['id'] as String,
        path: json['path'] as String,
        takenAt: json['takenAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'path': path,
        'takenAt': takenAt,
      };
}

class PhotoChapterPage {
  final String date;
  final int photoCount;
  final PhotoMemoryPick cover;
  final List<PhotoMemoryPick> picks;
  final String place;
  final List<String> scenes;
  final List<String> activities;
  final List<String> people;
  final String note;

  const PhotoChapterPage({
    required this.date,
    required this.photoCount,
    required this.cover,
    required this.picks,
    required this.place,
    required this.scenes,
    required this.activities,
    required this.people,
    required this.note,
  });

  factory PhotoChapterPage.fromJson(Map<String, dynamic> json) => PhotoChapterPage(
        date: json['date'] as String,
        photoCount: json['photoCount'] as int,
        cover: PhotoMemoryPick.fromJson(json['cover'] as Map<String, dynamic>),
        picks: (json['picks'] as List<dynamic>).map((e) => PhotoMemoryPick.fromJson(e as Map<String, dynamic>)).toList(),
        place: json['place'] as String,
        scenes: (json['scenes'] as List<dynamic>).cast<String>(),
        activities: (json['activities'] as List<dynamic>).cast<String>(),
        people: (json['people'] as List<dynamic>).cast<String>(),
        note: json['note'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'date': date,
        'photoCount': photoCount,
        'cover': cover.toJson(),
        'picks': picks.map((e) => e.toJson()).toList(),
        'place': place,
        'scenes': scenes,
        'activities': activities,
        'people': people,
        'note': note,
      };
}

class PhotoChapterBook {
  final int year;
  final String title;
  final int totalPhotos;
  final List<PhotoChapterPage> days;

  const PhotoChapterBook({
    required this.year,
    required this.title,
    required this.totalPhotos,
    required this.days,
  });

  factory PhotoChapterBook.fromJson(Map<String, dynamic> json) => PhotoChapterBook(
        year: json['year'] as int,
        title: json['title'] as String,
        totalPhotos: json['totalPhotos'] as int,
        days: (json['days'] as List<dynamic>).map((e) => PhotoChapterPage.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'year': year,
        'title': title,
        'totalPhotos': totalPhotos,
        'days': days.map((e) => e.toJson()).toList(),
      };
}

class PhotoTicket {
  final String kind;
  final String kindLabel;
  final String photoId;
  final String path;
  final int takenAt;
  final String date;
  final String time;
  final String fromStation;
  final String toStation;
  final String code;
  final List<String> evidence;

  const PhotoTicket({
    required this.kind,
    required this.kindLabel,
    required this.photoId,
    required this.path,
    required this.takenAt,
    required this.date,
    required this.time,
    required this.fromStation,
    required this.toStation,
    required this.code,
    required this.evidence,
  });

  factory PhotoTicket.fromJson(Map<String, dynamic> json) => PhotoTicket(
        kind: json['kind'] as String,
        kindLabel: json['kindLabel'] as String,
        photoId: json['photoId'] as String,
        path: json['path'] as String,
        takenAt: json['takenAt'] as int,
        date: json['date'] as String,
        time: json['time'] as String,
        fromStation: json['fromStation'] as String,
        toStation: json['toStation'] as String,
        code: json['code'] as String,
        evidence: (json['evidence'] as List<dynamic>).cast<String>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
        'kindLabel': kindLabel,
        'photoId': photoId,
        'path': path,
        'takenAt': takenAt,
        'date': date,
        'time': time,
        'fromStation': fromStation,
        'toStation': toStation,
        'code': code,
        'evidence': evidence,
      };
}

class PhotoTrip {
  final int index;
  final String start;
  final String end;
  final int ticketCount;
  final List<String> kinds;
  final String title;

  const PhotoTrip({
    required this.index,
    required this.start,
    required this.end,
    required this.ticketCount,
    required this.kinds,
    required this.title,
  });

  factory PhotoTrip.fromJson(Map<String, dynamic> json) => PhotoTrip(
        index: json['index'] as int,
        start: json['start'] as String,
        end: json['end'] as String,
        ticketCount: json['ticketCount'] as int,
        kinds: (json['kinds'] as List<dynamic>).cast<String>(),
        title: json['title'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'index': index,
        'start': start,
        'end': end,
        'ticketCount': ticketCount,
        'kinds': kinds,
        'title': title,
      };
}

class PhotoTicketResponse {
  final List<PhotoTicket> tickets;
  final List<PhotoTrip> trips;
  final bool degraded;
  final String reason;
  final int scanned;

  const PhotoTicketResponse({
    required this.tickets,
    required this.trips,
    required this.degraded,
    required this.reason,
    required this.scanned,
  });

  factory PhotoTicketResponse.fromJson(Map<String, dynamic> json) => PhotoTicketResponse(
        tickets: (json['tickets'] as List<dynamic>).map((e) => PhotoTicket.fromJson(e as Map<String, dynamic>)).toList(),
        trips: (json['trips'] as List<dynamic>).map((e) => PhotoTrip.fromJson(e as Map<String, dynamic>)).toList(),
        degraded: json['degraded'] as bool,
        reason: json['reason'] as String,
        scanned: json['scanned'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'tickets': tickets.map((e) => e.toJson()).toList(),
        'trips': trips.map((e) => e.toJson()).toList(),
        'degraded': degraded,
        'reason': reason,
        'scanned': scanned,
      };
}

class PhotoMonthCount {
  final int month;
  final int count;

  const PhotoMonthCount({
    required this.month,
    required this.count,
  });

  factory PhotoMonthCount.fromJson(Map<String, dynamic> json) => PhotoMonthCount(
        month: json['month'] as int,
        count: json['count'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'month': month,
        'count': count,
      };
}

class PhotoPlaceYear {
  final int year;
  final int count;

  const PhotoPlaceYear({
    required this.year,
    required this.count,
  });

  factory PhotoPlaceYear.fromJson(Map<String, dynamic> json) => PhotoPlaceYear(
        year: json['year'] as int,
        count: json['count'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'year': year,
        'count': count,
      };
}

class PhotoPlaceCount {
  final String geohash5;
  final String name;
  final int count;
  final List<PhotoPlaceYear> years;

  const PhotoPlaceCount({
    required this.geohash5,
    required this.name,
    required this.count,
    required this.years,
  });

  factory PhotoPlaceCount.fromJson(Map<String, dynamic> json) => PhotoPlaceCount(
        geohash5: json['geohash5'] as String,
        name: json['name'] as String,
        count: json['count'] as int,
        years: (json['years'] as List<dynamic>).map((e) => PhotoPlaceYear.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'geohash5': geohash5,
        'name': name,
        'count': count,
        'years': years.map((e) => e.toJson()).toList(),
      };
}

class PhotoLabelCount {
  final String label;
  final int count;

  const PhotoLabelCount({
    required this.label,
    required this.count,
  });

  factory PhotoLabelCount.fromJson(Map<String, dynamic> json) => PhotoLabelCount(
        label: json['label'] as String,
        count: json['count'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'label': label,
        'count': count,
      };
}

class PhotoYearReport {
  final int year;
  final int totalPhotos;
  final List<PhotoMonthCount> months;
  final List<PhotoPlaceCount> places;
  final int placeCount;
  final List<PhotoLabelCount> scenes;
  final List<PhotoLabelCount> activities;
  final List<PhotoLabelCount> people;
  final List<PhotoLabelCount> cameras;
  final List<PhotoLabelCount> busiestDays;
  final int? earliest;
  final int? latest;

  const PhotoYearReport({
    required this.year,
    required this.totalPhotos,
    required this.months,
    required this.places,
    required this.placeCount,
    required this.scenes,
    required this.activities,
    required this.people,
    required this.cameras,
    required this.busiestDays,
    required this.earliest,
    required this.latest,
  });

  factory PhotoYearReport.fromJson(Map<String, dynamic> json) => PhotoYearReport(
        year: json['year'] as int,
        totalPhotos: json['totalPhotos'] as int,
        months: (json['months'] as List<dynamic>).map((e) => PhotoMonthCount.fromJson(e as Map<String, dynamic>)).toList(),
        places: (json['places'] as List<dynamic>).map((e) => PhotoPlaceCount.fromJson(e as Map<String, dynamic>)).toList(),
        placeCount: json['placeCount'] as int,
        scenes: (json['scenes'] as List<dynamic>).map((e) => PhotoLabelCount.fromJson(e as Map<String, dynamic>)).toList(),
        activities: (json['activities'] as List<dynamic>).map((e) => PhotoLabelCount.fromJson(e as Map<String, dynamic>)).toList(),
        people: (json['people'] as List<dynamic>).map((e) => PhotoLabelCount.fromJson(e as Map<String, dynamic>)).toList(),
        cameras: (json['cameras'] as List<dynamic>).map((e) => PhotoLabelCount.fromJson(e as Map<String, dynamic>)).toList(),
        busiestDays: (json['busiestDays'] as List<dynamic>).map((e) => PhotoLabelCount.fromJson(e as Map<String, dynamic>)).toList(),
        earliest: json['earliest'] as int?,
        latest: json['latest'] as int?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'year': year,
        'totalPhotos': totalPhotos,
        'months': months.map((e) => e.toJson()).toList(),
        'places': places.map((e) => e.toJson()).toList(),
        'placeCount': placeCount,
        'scenes': scenes.map((e) => e.toJson()).toList(),
        'activities': activities.map((e) => e.toJson()).toList(),
        'people': people.map((e) => e.toJson()).toList(),
        'cameras': cameras.map((e) => e.toJson()).toList(),
        'busiestDays': busiestDays.map((e) => e.toJson()).toList(),
        'earliest': earliest,
        'latest': latest,
      };
}

class PhotoMemoryError {
  final String error;
  final String? message;
  final String? code;
  final String? traceId;
  final Map<String, dynamic>? details;

  const PhotoMemoryError({
    required this.error,
    this.message,
    this.code,
    this.traceId,
    this.details,
  });

  factory PhotoMemoryError.fromJson(Map<String, dynamic> json) => PhotoMemoryError(
        error: json['error'] as String,
        message: json['message'] == null ? null : json['message'] as String,
        code: json['code'] == null ? null : json['code'] as String,
        traceId: json['traceId'] == null ? null : json['traceId'] as String,
        details: json['details'] == null ? null : json['details'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'error': error,
        if (message != null) 'message': message!,
        if (code != null) 'code': code!,
        if (traceId != null) 'traceId': traceId!,
        if (details != null) 'details': details!,
      };
}

class PhotoBackupCheckFile {
  final String name;
  final int size;
  final String? md5;

  const PhotoBackupCheckFile({
    required this.name,
    required this.size,
    this.md5,
  });

  factory PhotoBackupCheckFile.fromJson(Map<String, dynamic> json) => PhotoBackupCheckFile(
        name: json['name'] as String,
        size: json['size'] as int,
        md5: json['md5'] == null ? null : json['md5'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'size': size,
        if (md5 != null) 'md5': md5!,
      };
}

class PhotoBackupCheckBody {
  final List<PhotoBackupCheckFile> files;

  const PhotoBackupCheckBody({
    required this.files,
  });

  factory PhotoBackupCheckBody.fromJson(Map<String, dynamic> json) => PhotoBackupCheckBody(
        files: (json['files'] as List<dynamic>).map((e) => PhotoBackupCheckFile.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'files': files.map((e) => e.toJson()).toList(),
      };
}

class PhotoBackupCheckResultFile {
  final String name;
  final int size;
  final String md5;

  const PhotoBackupCheckResultFile({
    required this.name,
    required this.size,
    required this.md5,
  });

  factory PhotoBackupCheckResultFile.fromJson(Map<String, dynamic> json) => PhotoBackupCheckResultFile(
        name: json['name'] as String,
        size: json['size'] as int,
        md5: json['md5'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'size': size,
        'md5': md5,
      };
}

class PhotoBackupCheckResponse {
  final List<PhotoBackupCheckResultFile> exists;
  final List<PhotoBackupCheckResultFile> missing;
  final int total;
  final int missingBytes;

  const PhotoBackupCheckResponse({
    required this.exists,
    required this.missing,
    required this.total,
    required this.missingBytes,
  });

  factory PhotoBackupCheckResponse.fromJson(Map<String, dynamic> json) => PhotoBackupCheckResponse(
        exists: (json['exists'] as List<dynamic>).map((e) => PhotoBackupCheckResultFile.fromJson(e as Map<String, dynamic>)).toList(),
        missing: (json['missing'] as List<dynamic>).map((e) => PhotoBackupCheckResultFile.fromJson(e as Map<String, dynamic>)).toList(),
        total: json['total'] as int,
        missingBytes: json['missingBytes'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'exists': exists.map((e) => e.toJson()).toList(),
        'missing': missing.map((e) => e.toJson()).toList(),
        'total': total,
        'missingBytes': missingBytes,
      };
}

class PhotoBackupCommitBody {
  final String? source;
  final int total;
  final int uploaded;
  final int skipped;
  final int bytes;

  const PhotoBackupCommitBody({
    this.source,
    required this.total,
    required this.uploaded,
    required this.skipped,
    required this.bytes,
  });

  factory PhotoBackupCommitBody.fromJson(Map<String, dynamic> json) => PhotoBackupCommitBody(
        source: json['source'] == null ? null : json['source'] as String,
        total: json['total'] as int,
        uploaded: json['uploaded'] as int,
        skipped: json['skipped'] as int,
        bytes: json['bytes'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (source != null) 'source': source!,
        'total': total,
        'uploaded': uploaded,
        'skipped': skipped,
        'bytes': bytes,
      };
}

class PhotoBackupJob {
  final String id;
  final String source;
  final int createdAt;
  final int? finishedAt;
  final int total;
  final int uploaded;
  final int skipped;
  final int bytes;

  const PhotoBackupJob({
    required this.id,
    required this.source,
    required this.createdAt,
    required this.finishedAt,
    required this.total,
    required this.uploaded,
    required this.skipped,
    required this.bytes,
  });

  factory PhotoBackupJob.fromJson(Map<String, dynamic> json) => PhotoBackupJob(
        id: json['id'] as String,
        source: json['source'] as String,
        createdAt: json['createdAt'] as int,
        finishedAt: json['finishedAt'] as int?,
        total: json['total'] as int,
        uploaded: json['uploaded'] as int,
        skipped: json['skipped'] as int,
        bytes: json['bytes'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'source': source,
        'createdAt': createdAt,
        'finishedAt': finishedAt,
        'total': total,
        'uploaded': uploaded,
        'skipped': skipped,
        'bytes': bytes,
      };
}

class PhotoBackupCommitResponse {
  final PhotoBackupJob job;

  const PhotoBackupCommitResponse({
    required this.job,
  });

  factory PhotoBackupCommitResponse.fromJson(Map<String, dynamic> json) => PhotoBackupCommitResponse(
        job: PhotoBackupJob.fromJson(json['job'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'job': job.toJson(),
      };
}

class PhotoBackupStatusResponse {
  final List<PhotoBackupJob> items;

  const PhotoBackupStatusResponse({
    required this.items,
  });

  factory PhotoBackupStatusResponse.fromJson(Map<String, dynamic> json) => PhotoBackupStatusResponse(
        items: (json['items'] as List<dynamic>).map((e) => PhotoBackupJob.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class PtDownloadSettings {
  final String movieLibraryId;
  final String tvLibraryId;
  final List<String> siteIds;
  final String quality;
  final String hdr;
  final List<String> audioLangs;
  final int maxSizeBytes;
  final int minSeeders;
  final List<String> excludedKeywords;
  final int scanIntervalMin;
  final bool autoDownload;

  const PtDownloadSettings({
    required this.movieLibraryId,
    required this.tvLibraryId,
    required this.siteIds,
    required this.quality,
    required this.hdr,
    required this.audioLangs,
    required this.maxSizeBytes,
    required this.minSeeders,
    required this.excludedKeywords,
    required this.scanIntervalMin,
    required this.autoDownload,
  });

  factory PtDownloadSettings.fromJson(Map<String, dynamic> json) => PtDownloadSettings(
        movieLibraryId: json['movieLibraryId'] as String,
        tvLibraryId: json['tvLibraryId'] as String,
        siteIds: (json['siteIds'] as List<dynamic>).cast<String>(),
        quality: json['quality'] as String,
        hdr: json['hdr'] as String,
        audioLangs: (json['audioLangs'] as List<dynamic>).cast<String>(),
        maxSizeBytes: json['maxSizeBytes'] as int,
        minSeeders: json['minSeeders'] as int,
        excludedKeywords: (json['excludedKeywords'] as List<dynamic>).cast<String>(),
        scanIntervalMin: json['scanIntervalMin'] as int,
        autoDownload: json['autoDownload'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'movieLibraryId': movieLibraryId,
        'tvLibraryId': tvLibraryId,
        'siteIds': siteIds,
        'quality': quality,
        'hdr': hdr,
        'audioLangs': audioLangs,
        'maxSizeBytes': maxSizeBytes,
        'minSeeders': minSeeders,
        'excludedKeywords': excludedKeywords,
        'scanIntervalMin': scanIntervalMin,
        'autoDownload': autoDownload,
      };
}

class PtDownloadSettingsBody {
  final String? movieLibraryId;
  final String? tvLibraryId;
  final List<String>? siteIds;
  final String? quality;
  final String? hdr;
  final List<String>? audioLangs;
  final int? maxSizeBytes;
  final int? minSeeders;
  final List<String>? excludedKeywords;
  final int? scanIntervalMin;
  final bool? autoDownload;

  const PtDownloadSettingsBody({
    this.movieLibraryId,
    this.tvLibraryId,
    this.siteIds,
    this.quality,
    this.hdr,
    this.audioLangs,
    this.maxSizeBytes,
    this.minSeeders,
    this.excludedKeywords,
    this.scanIntervalMin,
    this.autoDownload,
  });

  factory PtDownloadSettingsBody.fromJson(Map<String, dynamic> json) => PtDownloadSettingsBody(
        movieLibraryId: json['movieLibraryId'] == null ? null : json['movieLibraryId'] as String,
        tvLibraryId: json['tvLibraryId'] == null ? null : json['tvLibraryId'] as String,
        siteIds: json['siteIds'] == null ? null : (json['siteIds'] as List<dynamic>).cast<String>(),
        quality: json['quality'] == null ? null : json['quality'] as String,
        hdr: json['hdr'] == null ? null : json['hdr'] as String,
        audioLangs: json['audioLangs'] == null ? null : (json['audioLangs'] as List<dynamic>).cast<String>(),
        maxSizeBytes: json['maxSizeBytes'] == null ? null : json['maxSizeBytes'] as int,
        minSeeders: json['minSeeders'] == null ? null : json['minSeeders'] as int,
        excludedKeywords: json['excludedKeywords'] == null ? null : (json['excludedKeywords'] as List<dynamic>).cast<String>(),
        scanIntervalMin: json['scanIntervalMin'] == null ? null : json['scanIntervalMin'] as int,
        autoDownload: json['autoDownload'] == null ? null : json['autoDownload'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (movieLibraryId != null) 'movieLibraryId': movieLibraryId!,
        if (tvLibraryId != null) 'tvLibraryId': tvLibraryId!,
        if (siteIds != null) 'siteIds': siteIds!,
        if (quality != null) 'quality': quality!,
        if (hdr != null) 'hdr': hdr!,
        if (audioLangs != null) 'audioLangs': audioLangs!,
        if (maxSizeBytes != null) 'maxSizeBytes': maxSizeBytes!,
        if (minSeeders != null) 'minSeeders': minSeeders!,
        if (excludedKeywords != null) 'excludedKeywords': excludedKeywords!,
        if (scanIntervalMin != null) 'scanIntervalMin': scanIntervalMin!,
        if (autoDownload != null) 'autoDownload': autoDownload!,
      };
}

class PtDownloadSettingsResponse {
  final PtDownloadSettings settings;
  final String movieDir;
  final String tvDir;

  const PtDownloadSettingsResponse({
    required this.settings,
    required this.movieDir,
    required this.tvDir,
  });

  factory PtDownloadSettingsResponse.fromJson(Map<String, dynamic> json) => PtDownloadSettingsResponse(
        settings: PtDownloadSettings.fromJson(json['settings'] as Map<String, dynamic>),
        movieDir: json['movieDir'] as String,
        tvDir: json['tvDir'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'settings': settings.toJson(),
        'movieDir': movieDir,
        'tvDir': tvDir,
      };
}

class ErrorResponse {
  final String error;
  final String? message;
  final String? code;
  final String? traceId;
  final Map<String, dynamic>? details;

  const ErrorResponse({
    required this.error,
    this.message,
    this.code,
    this.traceId,
    this.details,
  });

  factory ErrorResponse.fromJson(Map<String, dynamic> json) => ErrorResponse(
        error: json['error'] as String,
        message: json['message'] == null ? null : json['message'] as String,
        code: json['code'] == null ? null : json['code'] as String,
        traceId: json['traceId'] == null ? null : json['traceId'] as String,
        details: json['details'] == null ? null : json['details'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'error': error,
        if (message != null) 'message': message!,
        if (code != null) 'code': code!,
        if (traceId != null) 'traceId': traceId!,
        if (details != null) 'details': details!,
      };
}

class SystemSettings {
  final int httpPort;
  final int httpsPort;
  final bool httpsEnabled;
  final int apiConcurrency;
  final String hostname;
  final String welcome;
  final String proxy;
  final bool javFallback;

  const SystemSettings({
    required this.httpPort,
    required this.httpsPort,
    required this.httpsEnabled,
    required this.apiConcurrency,
    required this.hostname,
    required this.welcome,
    required this.proxy,
    required this.javFallback,
  });

  factory SystemSettings.fromJson(Map<String, dynamic> json) => SystemSettings(
        httpPort: json['httpPort'] as int,
        httpsPort: json['httpsPort'] as int,
        httpsEnabled: json['httpsEnabled'] as bool,
        apiConcurrency: json['apiConcurrency'] as int,
        hostname: json['hostname'] as String,
        welcome: json['welcome'] as String,
        proxy: json['proxy'] as String,
        javFallback: json['javFallback'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'httpPort': httpPort,
        'httpsPort': httpsPort,
        'httpsEnabled': httpsEnabled,
        'apiConcurrency': apiConcurrency,
        'hostname': hostname,
        'welcome': welcome,
        'proxy': proxy,
        'javFallback': javFallback,
      };
}

class SystemSettingsBody {
  final int? httpPort;
  final int? httpsPort;
  final bool? httpsEnabled;
  final int? apiConcurrency;
  final String? hostname;
  final String? welcome;
  final String? proxy;
  final bool? javFallback;

  const SystemSettingsBody({
    this.httpPort,
    this.httpsPort,
    this.httpsEnabled,
    this.apiConcurrency,
    this.hostname,
    this.welcome,
    this.proxy,
    this.javFallback,
  });

  factory SystemSettingsBody.fromJson(Map<String, dynamic> json) => SystemSettingsBody(
        httpPort: json['httpPort'] == null ? null : json['httpPort'] as int,
        httpsPort: json['httpsPort'] == null ? null : json['httpsPort'] as int,
        httpsEnabled: json['httpsEnabled'] == null ? null : json['httpsEnabled'] as bool,
        apiConcurrency: json['apiConcurrency'] == null ? null : json['apiConcurrency'] as int,
        hostname: json['hostname'] == null ? null : json['hostname'] as String,
        welcome: json['welcome'] == null ? null : json['welcome'] as String,
        proxy: json['proxy'] == null ? null : json['proxy'] as String,
        javFallback: json['javFallback'] == null ? null : json['javFallback'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (httpPort != null) 'httpPort': httpPort!,
        if (httpsPort != null) 'httpsPort': httpsPort!,
        if (httpsEnabled != null) 'httpsEnabled': httpsEnabled!,
        if (apiConcurrency != null) 'apiConcurrency': apiConcurrency!,
        if (hostname != null) 'hostname': hostname!,
        if (welcome != null) 'welcome': welcome!,
        if (proxy != null) 'proxy': proxy!,
        if (javFallback != null) 'javFallback': javFallback!,
      };
}

class SystemSettingsResponse {
  final SystemSettings settings;
  final String activeProxy;

  const SystemSettingsResponse({
    required this.settings,
    required this.activeProxy,
  });

  factory SystemSettingsResponse.fromJson(Map<String, dynamic> json) => SystemSettingsResponse(
        settings: SystemSettings.fromJson(json['settings'] as Map<String, dynamic>),
        activeProxy: json['activeProxy'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'settings': settings.toJson(),
        'activeProxy': activeProxy,
      };
}

class SystemCacheClearResponse {
  final bool ok;
  final int freedBytes;
  final int files;

  const SystemCacheClearResponse({
    required this.ok,
    required this.freedBytes,
    required this.files,
  });

  factory SystemCacheClearResponse.fromJson(Map<String, dynamic> json) => SystemCacheClearResponse(
        ok: json['ok'] as bool,
        freedBytes: json['freedBytes'] as int,
        files: json['files'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        'freedBytes': freedBytes,
        'files': files,
      };
}

class SystemCacheInfoResponse {
  final int bytes;
  final int files;

  const SystemCacheInfoResponse({
    required this.bytes,
    required this.files,
  });

  factory SystemCacheInfoResponse.fromJson(Map<String, dynamic> json) => SystemCacheInfoResponse(
        bytes: json['bytes'] as int,
        files: json['files'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'bytes': bytes,
        'files': files,
      };
}

class SystemRestartResponse {
  final bool ok;

  const SystemRestartResponse({
    required this.ok,
  });

  factory SystemRestartResponse.fromJson(Map<String, dynamic> json) => SystemRestartResponse(
        ok: json['ok'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
      };
}

class SystemDbCompactResponse {
  final bool ok;
  final int beforeBytes;
  final int afterBytes;
  final int freedBytes;

  const SystemDbCompactResponse({
    required this.ok,
    required this.beforeBytes,
    required this.afterBytes,
    required this.freedBytes,
  });

  factory SystemDbCompactResponse.fromJson(Map<String, dynamic> json) => SystemDbCompactResponse(
        ok: json['ok'] as bool,
        beforeBytes: json['beforeBytes'] as int,
        afterBytes: json['afterBytes'] as int,
        freedBytes: json['freedBytes'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        'beforeBytes': beforeBytes,
        'afterBytes': afterBytes,
        'freedBytes': freedBytes,
      };
}

class SystemUpdateCheckResponse {
  final String? currentId;
  final int? currentVersion;
  final String? latestId;
  final int? latestVersion;
  final bool hasUpdate;
  final int versions;

  const SystemUpdateCheckResponse({
    required this.currentId,
    required this.currentVersion,
    required this.latestId,
    required this.latestVersion,
    required this.hasUpdate,
    required this.versions,
  });

  factory SystemUpdateCheckResponse.fromJson(Map<String, dynamic> json) => SystemUpdateCheckResponse(
        currentId: json['currentId'] as String?,
        currentVersion: json['currentVersion'] as int?,
        latestId: json['latestId'] as String?,
        latestVersion: json['latestVersion'] as int?,
        hasUpdate: json['hasUpdate'] as bool,
        versions: json['versions'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'currentId': currentId,
        'currentVersion': currentVersion,
        'latestId': latestId,
        'latestVersion': latestVersion,
        'hasUpdate': hasUpdate,
        'versions': versions,
      };
}

class SystemTlsInfoResponse {
  final bool hasCert;
  final String subject;
  final String validFrom;
  final String validTo;
  final bool enabled;
  final int port;

  const SystemTlsInfoResponse({
    required this.hasCert,
    required this.subject,
    required this.validFrom,
    required this.validTo,
    required this.enabled,
    required this.port,
  });

  factory SystemTlsInfoResponse.fromJson(Map<String, dynamic> json) => SystemTlsInfoResponse(
        hasCert: json['hasCert'] as bool,
        subject: json['subject'] as String,
        validFrom: json['validFrom'] as String,
        validTo: json['validTo'] as String,
        enabled: json['enabled'] as bool,
        port: json['port'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'hasCert': hasCert,
        'subject': subject,
        'validFrom': validFrom,
        'validTo': validTo,
        'enabled': enabled,
        'port': port,
      };
}

class SystemTlsUploadBody {
  final String cert;
  final String key;

  const SystemTlsUploadBody({
    required this.cert,
    required this.key,
  });

  factory SystemTlsUploadBody.fromJson(Map<String, dynamic> json) => SystemTlsUploadBody(
        cert: json['cert'] as String,
        key: json['key'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'cert': cert,
        'key': key,
      };
}

class SystemLogsResponse {
  final String file;
  final int size;
  final String updatedAt;
  final List<Map<String, dynamic>> lines;
  final bool truncated;

  const SystemLogsResponse({
    required this.file,
    required this.size,
    required this.updatedAt,
    required this.lines,
    required this.truncated,
  });

  factory SystemLogsResponse.fromJson(Map<String, dynamic> json) => SystemLogsResponse(
        file: json['file'] as String,
        size: json['size'] as int,
        updatedAt: json['updatedAt'] as String,
        lines: (json['lines'] as List<dynamic>).cast<Map<String, dynamic>>(),
        truncated: json['truncated'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'file': file,
        'size': size,
        'updatedAt': updatedAt,
        'lines': lines,
        'truncated': truncated,
      };
}

class VideoSourceItem {
  final String id;
  final String connType;
  final String path;
  final String? host;
  final String? share;
  final String? subPath;
  final String? username;
  final int? onlineState;
  final int? onlineCheckedAt;
  final int? items;
  final int? lastScanAt;

  const VideoSourceItem({
    required this.id,
    required this.connType,
    required this.path,
    this.host,
    this.share,
    this.subPath,
    this.username,
    this.onlineState,
    this.onlineCheckedAt,
    this.items,
    this.lastScanAt,
  });

  factory VideoSourceItem.fromJson(Map<String, dynamic> json) => VideoSourceItem(
        id: json['id'] as String,
        connType: json['connType'] as String,
        path: json['path'] as String,
        host: json['host'] == null ? null : json['host'] as String?,
        share: json['share'] == null ? null : json['share'] as String?,
        subPath: json['subPath'] == null ? null : json['subPath'] as String?,
        username: json['username'] == null ? null : json['username'] as String?,
        onlineState: json['onlineState'] == null ? null : json['onlineState'] as int,
        onlineCheckedAt: json['onlineCheckedAt'] == null ? null : json['onlineCheckedAt'] as int?,
        items: json['items'] == null ? null : json['items'] as int,
        lastScanAt: json['lastScanAt'] == null ? null : json['lastScanAt'] as int?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'connType': connType,
        'path': path,
        if (host != null) 'host': host!,
        if (share != null) 'share': share!,
        if (subPath != null) 'subPath': subPath!,
        if (username != null) 'username': username!,
        if (onlineState != null) 'onlineState': onlineState!,
        if (onlineCheckedAt != null) 'onlineCheckedAt': onlineCheckedAt!,
        if (items != null) 'items': items!,
        if (lastScanAt != null) 'lastScanAt': lastScanAt!,
      };
}

class VideoSourceInput {
  final dynamic connType;
  final String? path;
  final String? host;
  final String? share;
  final String? subPath;
  final String? username;
  final String? password;

  const VideoSourceInput({
    this.connType,
    this.path,
    this.host,
    this.share,
    this.subPath,
    this.username,
    this.password,
  });

  factory VideoSourceInput.fromJson(Map<String, dynamic> json) => VideoSourceInput(
        connType: json['connType'] == null ? null : (json['connType'] as dynamic),
        path: json['path'] == null ? null : json['path'] as String,
        host: json['host'] == null ? null : json['host'] as String,
        share: json['share'] == null ? null : json['share'] as String,
        subPath: json['subPath'] == null ? null : json['subPath'] as String,
        username: json['username'] == null ? null : json['username'] as String,
        password: json['password'] == null ? null : json['password'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (connType != null) 'connType': connType!,
        if (path != null) 'path': path!,
        if (host != null) 'host': host!,
        if (share != null) 'share': share!,
        if (subPath != null) 'subPath': subPath!,
        if (username != null) 'username': username!,
        if (password != null) 'password': password!,
      };
}

class VideoLibraryItem {
  final String id;
  final String name;
  final String path;
  final int items;
  final int createdAt;
  final int? lastScanAt;
  final String libType;
  final String? connType;
  final int? onlineState;
  final int? onlineCheckedAt;
  final int? showInHome;
  final int? sortOrder;
  final int? audioNormalize;
  final int? scrapeEnabled;
  final int? autoScrape;
  final int? autoSubtitle;
  final List<VideoSourceItem>? sources;

  const VideoLibraryItem({
    required this.id,
    required this.name,
    required this.path,
    required this.items,
    required this.createdAt,
    required this.lastScanAt,
    required this.libType,
    this.connType,
    this.onlineState,
    this.onlineCheckedAt,
    this.showInHome,
    this.sortOrder,
    this.audioNormalize,
    this.scrapeEnabled,
    this.autoScrape,
    this.autoSubtitle,
    this.sources,
  });

  factory VideoLibraryItem.fromJson(Map<String, dynamic> json) => VideoLibraryItem(
        id: json['id'] as String,
        name: json['name'] as String,
        path: json['path'] as String,
        items: json['items'] as int,
        createdAt: json['createdAt'] as int,
        lastScanAt: json['lastScanAt'] as int?,
        libType: json['libType'] as String,
        connType: json['connType'] == null ? null : json['connType'] as String,
        onlineState: json['onlineState'] == null ? null : json['onlineState'] as int,
        onlineCheckedAt: json['onlineCheckedAt'] == null ? null : json['onlineCheckedAt'] as int?,
        showInHome: json['showInHome'] == null ? null : json['showInHome'] as int,
        sortOrder: json['sortOrder'] == null ? null : json['sortOrder'] as int,
        audioNormalize: json['audioNormalize'] == null ? null : json['audioNormalize'] as int,
        scrapeEnabled: json['scrapeEnabled'] == null ? null : json['scrapeEnabled'] as int,
        autoScrape: json['autoScrape'] == null ? null : json['autoScrape'] as int,
        autoSubtitle: json['autoSubtitle'] == null ? null : json['autoSubtitle'] as int,
        sources: json['sources'] == null ? null : (json['sources'] as List<dynamic>).map((e) => VideoSourceItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'path': path,
        'items': items,
        'createdAt': createdAt,
        'lastScanAt': lastScanAt,
        'libType': libType,
        if (connType != null) 'connType': connType!,
        if (onlineState != null) 'onlineState': onlineState!,
        if (onlineCheckedAt != null) 'onlineCheckedAt': onlineCheckedAt!,
        if (showInHome != null) 'showInHome': showInHome!,
        if (sortOrder != null) 'sortOrder': sortOrder!,
        if (audioNormalize != null) 'audioNormalize': audioNormalize!,
        if (scrapeEnabled != null) 'scrapeEnabled': scrapeEnabled!,
        if (autoScrape != null) 'autoScrape': autoScrape!,
        if (autoSubtitle != null) 'autoSubtitle': autoSubtitle!,
        if (sources != null) 'sources': sources!.map((e) => e.toJson()).toList(),
      };
}

class VideoLibraryUpdateBody {
  final String id;
  final String? name;
  final String? libType;
  final dynamic connType;
  final String? path;
  final String? host;
  final String? share;
  final String? subPath;
  final String? username;
  final String? password;
  final List<VideoSourceInput>? sources;

  const VideoLibraryUpdateBody({
    required this.id,
    this.name,
    this.libType,
    this.connType,
    this.path,
    this.host,
    this.share,
    this.subPath,
    this.username,
    this.password,
    this.sources,
  });

  factory VideoLibraryUpdateBody.fromJson(Map<String, dynamic> json) => VideoLibraryUpdateBody(
        id: json['id'] as String,
        name: json['name'] == null ? null : json['name'] as String,
        libType: json['libType'] == null ? null : json['libType'] as String,
        connType: json['connType'] == null ? null : (json['connType'] as dynamic),
        path: json['path'] == null ? null : json['path'] as String,
        host: json['host'] == null ? null : json['host'] as String,
        share: json['share'] == null ? null : json['share'] as String,
        subPath: json['subPath'] == null ? null : json['subPath'] as String,
        username: json['username'] == null ? null : json['username'] as String,
        password: json['password'] == null ? null : json['password'] as String,
        sources: json['sources'] == null ? null : (json['sources'] as List<dynamic>).map((e) => VideoSourceInput.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (name != null) 'name': name!,
        if (libType != null) 'libType': libType!,
        if (connType != null) 'connType': connType!,
        if (path != null) 'path': path!,
        if (host != null) 'host': host!,
        if (share != null) 'share': share!,
        if (subPath != null) 'subPath': subPath!,
        if (username != null) 'username': username!,
        if (password != null) 'password': password!,
        if (sources != null) 'sources': sources!.map((e) => e.toJson()).toList(),
      };
}

class VideoLibraryFlagsBody {
  final String id;
  final bool? showInHome;
  final int? sortOrder;
  final bool? audioNormalize;
  final bool? scrapeEnabled;
  final bool? autoScrape;
  final bool? autoSubtitle;

  const VideoLibraryFlagsBody({
    required this.id,
    this.showInHome,
    this.sortOrder,
    this.audioNormalize,
    this.scrapeEnabled,
    this.autoScrape,
    this.autoSubtitle,
  });

  factory VideoLibraryFlagsBody.fromJson(Map<String, dynamic> json) => VideoLibraryFlagsBody(
        id: json['id'] as String,
        showInHome: json['showInHome'] == null ? null : json['showInHome'] as bool,
        sortOrder: json['sortOrder'] == null ? null : json['sortOrder'] as int,
        audioNormalize: json['audioNormalize'] == null ? null : json['audioNormalize'] as bool,
        scrapeEnabled: json['scrapeEnabled'] == null ? null : json['scrapeEnabled'] as bool,
        autoScrape: json['autoScrape'] == null ? null : json['autoScrape'] as bool,
        autoSubtitle: json['autoSubtitle'] == null ? null : json['autoSubtitle'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (showInHome != null) 'showInHome': showInHome!,
        if (sortOrder != null) 'sortOrder': sortOrder!,
        if (audioNormalize != null) 'audioNormalize': audioNormalize!,
        if (scrapeEnabled != null) 'scrapeEnabled': scrapeEnabled!,
        if (autoScrape != null) 'autoScrape': autoScrape!,
        if (autoSubtitle != null) 'autoSubtitle': autoSubtitle!,
      };
}

class VideoSourceProbeBody {
  final String? id;
  final String? sourceId;
  final String? host;

  const VideoSourceProbeBody({
    this.id,
    this.sourceId,
    this.host,
  });

  factory VideoSourceProbeBody.fromJson(Map<String, dynamic> json) => VideoSourceProbeBody(
        id: json['id'] == null ? null : json['id'] as String,
        sourceId: json['sourceId'] == null ? null : json['sourceId'] as String,
        host: json['host'] == null ? null : json['host'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (id != null) 'id': id!,
        if (sourceId != null) 'sourceId': sourceId!,
        if (host != null) 'host': host!,
      };
}

class VideoSourceProbeResponse {
  final String? id;
  final String? sourceId;
  final String host;
  final int onlineState;
  final int checkedAt;

  const VideoSourceProbeResponse({
    required this.id,
    this.sourceId,
    required this.host,
    required this.onlineState,
    required this.checkedAt,
  });

  factory VideoSourceProbeResponse.fromJson(Map<String, dynamic> json) => VideoSourceProbeResponse(
        id: json['id'] as String?,
        sourceId: json['sourceId'] == null ? null : json['sourceId'] as String?,
        host: json['host'] as String,
        onlineState: json['onlineState'] as int,
        checkedAt: json['checkedAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (sourceId != null) 'sourceId': sourceId!,
        'host': host,
        'onlineState': onlineState,
        'checkedAt': checkedAt,
      };
}

class VideoLibraryListResponse {
  final List<VideoLibraryItem> items;

  const VideoLibraryListResponse({
    required this.items,
  });

  factory VideoLibraryListResponse.fromJson(Map<String, dynamic> json) => VideoLibraryListResponse(
        items: (json['items'] as List<dynamic>).map((e) => VideoLibraryItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class VideoLibraryCreateBody {
  final String name;
  final String? path;
  final dynamic connType;
  final String? host;
  final String? share;
  final String? subPath;
  final String? username;
  final String? password;
  final String? libType;
  final List<VideoSourceInput>? sources;

  const VideoLibraryCreateBody({
    required this.name,
    this.path,
    this.connType,
    this.host,
    this.share,
    this.subPath,
    this.username,
    this.password,
    this.libType,
    this.sources,
  });

  factory VideoLibraryCreateBody.fromJson(Map<String, dynamic> json) => VideoLibraryCreateBody(
        name: json['name'] as String,
        path: json['path'] == null ? null : json['path'] as String,
        connType: json['connType'] == null ? null : (json['connType'] as dynamic),
        host: json['host'] == null ? null : json['host'] as String,
        share: json['share'] == null ? null : json['share'] as String,
        subPath: json['subPath'] == null ? null : json['subPath'] as String,
        username: json['username'] == null ? null : json['username'] as String,
        password: json['password'] == null ? null : json['password'] as String,
        libType: json['libType'] == null ? null : json['libType'] as String,
        sources: json['sources'] == null ? null : (json['sources'] as List<dynamic>).map((e) => VideoSourceInput.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        if (path != null) 'path': path!,
        if (connType != null) 'connType': connType!,
        if (host != null) 'host': host!,
        if (share != null) 'share': share!,
        if (subPath != null) 'subPath': subPath!,
        if (username != null) 'username': username!,
        if (password != null) 'password': password!,
        if (libType != null) 'libType': libType!,
        if (sources != null) 'sources': sources!.map((e) => e.toJson()).toList(),
      };
}

class VideoLibraryRemoveBody {
  final String id;

  const VideoLibraryRemoveBody({
    required this.id,
  });

  factory VideoLibraryRemoveBody.fromJson(Map<String, dynamic> json) => VideoLibraryRemoveBody(
        id: json['id'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
      };
}

class VideoScanBody {
  final String? libraryId;
  final int? limit;
  final bool? prune;

  const VideoScanBody({
    this.libraryId,
    this.limit,
    this.prune,
  });

  factory VideoScanBody.fromJson(Map<String, dynamic> json) => VideoScanBody(
        libraryId: json['libraryId'] == null ? null : json['libraryId'] as String,
        limit: json['limit'] == null ? null : json['limit'] as int,
        prune: json['prune'] == null ? null : json['prune'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (libraryId != null) 'libraryId': libraryId!,
        if (limit != null) 'limit': limit!,
        if (prune != null) 'prune': prune!,
      };
}

class VideoScanResponse {
  final int libraries;
  final int videos;
  final int images;
  final int added;
  final int updated;
  final int skipped;
  final int probed;
  final int? missing;
  final int? pruned;
  final int? nfoFilled;
  final List<String>? errors;

  const VideoScanResponse({
    required this.libraries,
    required this.videos,
    required this.images,
    required this.added,
    required this.updated,
    required this.skipped,
    required this.probed,
    this.missing,
    this.pruned,
    this.nfoFilled,
    this.errors,
  });

  factory VideoScanResponse.fromJson(Map<String, dynamic> json) => VideoScanResponse(
        libraries: json['libraries'] as int,
        videos: json['videos'] as int,
        images: json['images'] as int,
        added: json['added'] as int,
        updated: json['updated'] as int,
        skipped: json['skipped'] as int,
        probed: json['probed'] as int,
        missing: json['missing'] == null ? null : json['missing'] as int,
        pruned: json['pruned'] == null ? null : json['pruned'] as int,
        nfoFilled: json['nfoFilled'] == null ? null : json['nfoFilled'] as int,
        errors: json['errors'] == null ? null : (json['errors'] as List<dynamic>).cast<String>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'libraries': libraries,
        'videos': videos,
        'images': images,
        'added': added,
        'updated': updated,
        'skipped': skipped,
        'probed': probed,
        if (missing != null) 'missing': missing!,
        if (pruned != null) 'pruned': pruned!,
        if (nfoFilled != null) 'nfoFilled': nfoFilled!,
        if (errors != null) 'errors': errors!,
      };
}

class VideoItem {
  final String id;
  final String libraryId;
  final String mediaType;
  final String path;
  final String title;
  final String fileTitle;
  final int? durationMs;
  final int? width;
  final int? height;
  final String? videoCodec;
  final String? audioCodec;
  final String container;
  final bool hasSubtitle;
  final int size;
  final String? series;
  final int? season;
  final int? episode;
  final int? takenAt;
  final String? code;
  final bool uncensored;
  final bool chineseSub;
  final int? rankDaily;
  final int? rankWeekly;
  final int? rankMonthly;
  final bool favorite;
  final bool is4k;
  final bool hdr10;
  final bool hdr10plus;
  final bool hlg;
  final bool dolbyVision;
  final bool dolbyAtmos;
  final String? originalName;
  final int? year;
  final double? score;
  final String? overview;
  final int? runtimeMin;
  final String? releaseDate;
  final String? studio;
  final List<String> genres;
  final List<String> regions;
  final List<String> actors;
  final List<String> directors;
  final bool hasArt;
  final String? imdbId;
  final String? doubanId;
  final int? tmdbId;
  final dynamic nfoSource;
  final bool watched;

  const VideoItem({
    required this.id,
    required this.libraryId,
    required this.mediaType,
    required this.path,
    required this.title,
    required this.fileTitle,
    required this.durationMs,
    required this.width,
    required this.height,
    required this.videoCodec,
    required this.audioCodec,
    required this.container,
    required this.hasSubtitle,
    required this.size,
    required this.series,
    required this.season,
    required this.episode,
    required this.takenAt,
    required this.code,
    required this.uncensored,
    required this.chineseSub,
    this.rankDaily,
    this.rankWeekly,
    this.rankMonthly,
    required this.favorite,
    required this.is4k,
    required this.hdr10,
    required this.hdr10plus,
    required this.hlg,
    required this.dolbyVision,
    required this.dolbyAtmos,
    required this.originalName,
    required this.year,
    required this.score,
    required this.overview,
    required this.runtimeMin,
    required this.releaseDate,
    required this.studio,
    required this.genres,
    required this.regions,
    required this.actors,
    required this.directors,
    required this.hasArt,
    required this.imdbId,
    required this.doubanId,
    required this.tmdbId,
    required this.nfoSource,
    required this.watched,
  });

  factory VideoItem.fromJson(Map<String, dynamic> json) => VideoItem(
        id: json['id'] as String,
        libraryId: json['libraryId'] as String,
        mediaType: json['mediaType'] as String,
        path: json['path'] as String,
        title: json['title'] as String,
        fileTitle: json['fileTitle'] as String,
        durationMs: json['durationMs'] as int?,
        width: json['width'] as int?,
        height: json['height'] as int?,
        videoCodec: json['videoCodec'] as String?,
        audioCodec: json['audioCodec'] as String?,
        container: json['container'] as String,
        hasSubtitle: json['hasSubtitle'] as bool,
        size: json['size'] as int,
        series: json['series'] as String?,
        season: json['season'] as int?,
        episode: json['episode'] as int?,
        takenAt: json['takenAt'] as int?,
        code: json['code'] as String?,
        uncensored: json['uncensored'] as bool,
        chineseSub: json['chineseSub'] as bool,
        rankDaily: json['rankDaily'] == null ? null : json['rankDaily'] as int?,
        rankWeekly: json['rankWeekly'] == null ? null : json['rankWeekly'] as int?,
        rankMonthly: json['rankMonthly'] == null ? null : json['rankMonthly'] as int?,
        favorite: json['favorite'] as bool,
        is4k: json['is4k'] as bool,
        hdr10: json['hdr10'] as bool,
        hdr10plus: json['hdr10plus'] as bool,
        hlg: json['hlg'] as bool,
        dolbyVision: json['dolbyVision'] as bool,
        dolbyAtmos: json['dolbyAtmos'] as bool,
        originalName: json['originalName'] as String?,
        year: json['year'] as int?,
        score: (json['score'] as num?)?.toDouble(),
        overview: json['overview'] as String?,
        runtimeMin: json['runtimeMin'] as int?,
        releaseDate: json['releaseDate'] as String?,
        studio: json['studio'] as String?,
        genres: (json['genres'] as List<dynamic>).cast<String>(),
        regions: (json['regions'] as List<dynamic>).cast<String>(),
        actors: (json['actors'] as List<dynamic>).cast<String>(),
        directors: (json['directors'] as List<dynamic>).cast<String>(),
        hasArt: json['hasArt'] as bool,
        imdbId: json['imdbId'] as String?,
        doubanId: json['doubanId'] as String?,
        tmdbId: json['tmdbId'] as int?,
        nfoSource: (json['nfoSource'] as dynamic),
        watched: json['watched'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'libraryId': libraryId,
        'mediaType': mediaType,
        'path': path,
        'title': title,
        'fileTitle': fileTitle,
        'durationMs': durationMs,
        'width': width,
        'height': height,
        'videoCodec': videoCodec,
        'audioCodec': audioCodec,
        'container': container,
        'hasSubtitle': hasSubtitle,
        'size': size,
        'series': series,
        'season': season,
        'episode': episode,
        'takenAt': takenAt,
        'code': code,
        'uncensored': uncensored,
        'chineseSub': chineseSub,
        if (rankDaily != null) 'rankDaily': rankDaily!,
        if (rankWeekly != null) 'rankWeekly': rankWeekly!,
        if (rankMonthly != null) 'rankMonthly': rankMonthly!,
        'favorite': favorite,
        'is4k': is4k,
        'hdr10': hdr10,
        'hdr10plus': hdr10plus,
        'hlg': hlg,
        'dolbyVision': dolbyVision,
        'dolbyAtmos': dolbyAtmos,
        'originalName': originalName,
        'year': year,
        'score': score,
        'overview': overview,
        'runtimeMin': runtimeMin,
        'releaseDate': releaseDate,
        'studio': studio,
        'genres': genres,
        'regions': regions,
        'actors': actors,
        'directors': directors,
        'hasArt': hasArt,
        'imdbId': imdbId,
        'doubanId': doubanId,
        'tmdbId': tmdbId,
        'nfoSource': nfoSource,
        'watched': watched,
      };
}

class VideoFavoriteBody {
  final List<String> ids;
  final bool favorite;

  const VideoFavoriteBody({
    required this.ids,
    required this.favorite,
  });

  factory VideoFavoriteBody.fromJson(Map<String, dynamic> json) => VideoFavoriteBody(
        ids: (json['ids'] as List<dynamic>).cast<String>(),
        favorite: json['favorite'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ids': ids,
        'favorite': favorite,
      };
}

class VideoFavoriteResponse {
  final int updated;

  const VideoFavoriteResponse({
    required this.updated,
  });

  factory VideoFavoriteResponse.fromJson(Map<String, dynamic> json) => VideoFavoriteResponse(
        updated: json['updated'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'updated': updated,
      };
}

class VideoCollection {
  final String id;
  final String name;
  final String kind;
  final int items;
  final int createdAt;
  final int updatedAt;
  final String? description;
  final String? coverItemId;
  final String? coverPath;
  final int? sortOrder;

  const VideoCollection({
    required this.id,
    required this.name,
    required this.kind,
    required this.items,
    required this.createdAt,
    required this.updatedAt,
    this.description,
    this.coverItemId,
    this.coverPath,
    this.sortOrder,
  });

  factory VideoCollection.fromJson(Map<String, dynamic> json) => VideoCollection(
        id: json['id'] as String,
        name: json['name'] as String,
        kind: json['kind'] as String,
        items: json['items'] as int,
        createdAt: json['createdAt'] as int,
        updatedAt: json['updatedAt'] as int,
        description: json['description'] == null ? null : json['description'] as String?,
        coverItemId: json['coverItemId'] == null ? null : json['coverItemId'] as String?,
        coverPath: json['coverPath'] == null ? null : json['coverPath'] as String?,
        sortOrder: json['sortOrder'] == null ? null : json['sortOrder'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'kind': kind,
        'items': items,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        if (description != null) 'description': description!,
        if (coverItemId != null) 'coverItemId': coverItemId!,
        if (coverPath != null) 'coverPath': coverPath!,
        if (sortOrder != null) 'sortOrder': sortOrder!,
      };
}

class VideoCollectionListResponse {
  final List<VideoCollection> items;

  const VideoCollectionListResponse({
    required this.items,
  });

  factory VideoCollectionListResponse.fromJson(Map<String, dynamic> json) => VideoCollectionListResponse(
        items: (json['items'] as List<dynamic>).map((e) => VideoCollection.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class VideoCollectionUpsertBody {
  final String? id;
  final String name;
  final String? kind;
  final String? description;
  final String? coverItemId;
  final int? sortOrder;

  const VideoCollectionUpsertBody({
    this.id,
    required this.name,
    this.kind,
    this.description,
    this.coverItemId,
    this.sortOrder,
  });

  factory VideoCollectionUpsertBody.fromJson(Map<String, dynamic> json) => VideoCollectionUpsertBody(
        id: json['id'] == null ? null : json['id'] as String,
        name: json['name'] as String,
        kind: json['kind'] == null ? null : json['kind'] as String,
        description: json['description'] == null ? null : json['description'] as String?,
        coverItemId: json['coverItemId'] == null ? null : json['coverItemId'] as String?,
        sortOrder: json['sortOrder'] == null ? null : json['sortOrder'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (id != null) 'id': id!,
        'name': name,
        if (kind != null) 'kind': kind!,
        if (description != null) 'description': description!,
        if (coverItemId != null) 'coverItemId': coverItemId!,
        if (sortOrder != null) 'sortOrder': sortOrder!,
      };
}

class VideoCollectionIdBody {
  final String id;

  const VideoCollectionIdBody({
    required this.id,
  });

  factory VideoCollectionIdBody.fromJson(Map<String, dynamic> json) => VideoCollectionIdBody(
        id: json['id'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
      };
}

class VideoCollectionItemsBody {
  final String id;
  final List<String> itemIds;
  final dynamic action;

  const VideoCollectionItemsBody({
    required this.id,
    required this.itemIds,
    required this.action,
  });

  factory VideoCollectionItemsBody.fromJson(Map<String, dynamic> json) => VideoCollectionItemsBody(
        id: json['id'] as String,
        itemIds: (json['itemIds'] as List<dynamic>).cast<String>(),
        action: (json['action'] as dynamic),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'itemIds': itemIds,
        'action': action,
      };
}

class VideoCollectionItemsResponse {
  final String id;
  final String name;
  final List<VideoItem> items;

  const VideoCollectionItemsResponse({
    required this.id,
    required this.name,
    required this.items,
  });

  factory VideoCollectionItemsResponse.fromJson(Map<String, dynamic> json) => VideoCollectionItemsResponse(
        id: json['id'] as String,
        name: json['name'] as String,
        items: (json['items'] as List<dynamic>).map((e) => VideoItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class VideoBrowseItem {
  final String name;
  final String path;
  final bool dir;
  final String mediaType;
  final String? id;
  final int? size;
  final int? mtime;

  const VideoBrowseItem({
    required this.name,
    required this.path,
    required this.dir,
    required this.mediaType,
    required this.id,
    required this.size,
    required this.mtime,
  });

  factory VideoBrowseItem.fromJson(Map<String, dynamic> json) => VideoBrowseItem(
        name: json['name'] as String,
        path: json['path'] as String,
        dir: json['dir'] as bool,
        mediaType: json['mediaType'] as String,
        id: json['id'] as String?,
        size: json['size'] as int?,
        mtime: json['mtime'] as int?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'path': path,
        'dir': dir,
        'mediaType': mediaType,
        'id': id,
        'size': size,
        'mtime': mtime,
      };
}

class VideoBrowseResponse {
  final String libraryId;
  final String path;
  final String rootPath;
  final List<VideoBrowseItem> items;

  const VideoBrowseResponse({
    required this.libraryId,
    required this.path,
    required this.rootPath,
    required this.items,
  });

  factory VideoBrowseResponse.fromJson(Map<String, dynamic> json) => VideoBrowseResponse(
        libraryId: json['libraryId'] as String,
        path: json['path'] as String,
        rootPath: json['rootPath'] as String,
        items: (json['items'] as List<dynamic>).map((e) => VideoBrowseItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'libraryId': libraryId,
        'path': path,
        'rootPath': rootPath,
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class VideoDuplicateItem {
  final String id;
  final String title;
  final String path;
  final int size;
  final int mtime;
  final int? durationMs;
  final int? width;
  final int? height;
  final String? videoCodec;
  final String? code;
  final int? year;
  final double? score;
  final bool hasArt;
  final String? imdbId;
  final String? doubanId;
  final bool uncensored;
  final bool chineseSub;
  final bool is4k;
  final bool hdr;
  final bool dolbyVision;
  final bool dolbyAtmos;
  final bool ltx;
  final bool isJp;
  final List<String> actorKeys;
  final String part;
  final bool suggestedKeep;

  const VideoDuplicateItem({
    required this.id,
    required this.title,
    required this.path,
    required this.size,
    required this.mtime,
    required this.durationMs,
    required this.width,
    required this.height,
    required this.videoCodec,
    required this.code,
    required this.year,
    required this.score,
    required this.hasArt,
    required this.imdbId,
    required this.doubanId,
    required this.uncensored,
    required this.chineseSub,
    required this.is4k,
    required this.hdr,
    required this.dolbyVision,
    required this.dolbyAtmos,
    required this.ltx,
    required this.isJp,
    required this.actorKeys,
    required this.part,
    required this.suggestedKeep,
  });

  factory VideoDuplicateItem.fromJson(Map<String, dynamic> json) => VideoDuplicateItem(
        id: json['id'] as String,
        title: json['title'] as String,
        path: json['path'] as String,
        size: json['size'] as int,
        mtime: json['mtime'] as int,
        durationMs: json['durationMs'] as int?,
        width: json['width'] as int?,
        height: json['height'] as int?,
        videoCodec: json['videoCodec'] as String?,
        code: json['code'] as String?,
        year: json['year'] as int?,
        score: (json['score'] as num?)?.toDouble(),
        hasArt: json['hasArt'] as bool,
        imdbId: json['imdbId'] as String?,
        doubanId: json['doubanId'] as String?,
        uncensored: json['uncensored'] as bool,
        chineseSub: json['chineseSub'] as bool,
        is4k: json['is4k'] as bool,
        hdr: json['hdr'] as bool,
        dolbyVision: json['dolbyVision'] as bool,
        dolbyAtmos: json['dolbyAtmos'] as bool,
        ltx: json['ltx'] as bool,
        isJp: json['isJp'] as bool,
        actorKeys: (json['actorKeys'] as List<dynamic>).cast<String>(),
        part: json['part'] as String,
        suggestedKeep: json['suggestedKeep'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'path': path,
        'size': size,
        'mtime': mtime,
        'durationMs': durationMs,
        'width': width,
        'height': height,
        'videoCodec': videoCodec,
        'code': code,
        'year': year,
        'score': score,
        'hasArt': hasArt,
        'imdbId': imdbId,
        'doubanId': doubanId,
        'uncensored': uncensored,
        'chineseSub': chineseSub,
        'is4k': is4k,
        'hdr': hdr,
        'dolbyVision': dolbyVision,
        'dolbyAtmos': dolbyAtmos,
        'ltx': ltx,
        'isJp': isJp,
        'actorKeys': actorKeys,
        'part': part,
        'suggestedKeep': suggestedKeep,
      };
}

class VideoDuplicateGroup {
  final String key;
  final String title;
  final int count;
  final List<String> keys;
  final List<VideoDuplicateItem> items;

  const VideoDuplicateGroup({
    required this.key,
    required this.title,
    required this.count,
    required this.keys,
    required this.items,
  });

  factory VideoDuplicateGroup.fromJson(Map<String, dynamic> json) => VideoDuplicateGroup(
        key: json['key'] as String,
        title: json['title'] as String,
        count: json['count'] as int,
        keys: (json['keys'] as List<dynamic>).cast<String>(),
        items: (json['items'] as List<dynamic>).map((e) => VideoDuplicateItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'title': title,
        'count': count,
        'keys': keys,
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class VideoDuplicatesResponse {
  final List<VideoDuplicateGroup> groups;
  final int totalGroups;
  final int scanned;
  final int tookMs;

  const VideoDuplicatesResponse({
    required this.groups,
    required this.totalGroups,
    required this.scanned,
    required this.tookMs,
  });

  factory VideoDuplicatesResponse.fromJson(Map<String, dynamic> json) => VideoDuplicatesResponse(
        groups: (json['groups'] as List<dynamic>).map((e) => VideoDuplicateGroup.fromJson(e as Map<String, dynamic>)).toList(),
        totalGroups: json['totalGroups'] as int,
        scanned: json['scanned'] as int,
        tookMs: json['tookMs'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'groups': groups.map((e) => e.toJson()).toList(),
        'totalGroups': totalGroups,
        'scanned': scanned,
        'tookMs': tookMs,
      };
}

class VideoDeleteItemsBody {
  final List<String> ids;
  final bool? permanent;

  const VideoDeleteItemsBody({
    required this.ids,
    this.permanent,
  });

  factory VideoDeleteItemsBody.fromJson(Map<String, dynamic> json) => VideoDeleteItemsBody(
        ids: (json['ids'] as List<dynamic>).cast<String>(),
        permanent: json['permanent'] == null ? null : json['permanent'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ids': ids,
        if (permanent != null) 'permanent': permanent!,
      };
}

class VideoDeleteItemsResponse {
  final List<String> done;
  final List<Map<String, dynamic>> failed;
  final String trashedTo;
  final List<String>? sidecars;

  const VideoDeleteItemsResponse({
    required this.done,
    required this.failed,
    required this.trashedTo,
    this.sidecars,
  });

  factory VideoDeleteItemsResponse.fromJson(Map<String, dynamic> json) => VideoDeleteItemsResponse(
        done: (json['done'] as List<dynamic>).cast<String>(),
        failed: (json['failed'] as List<dynamic>).cast<Map<String, dynamic>>(),
        trashedTo: json['trashedTo'] as String,
        sidecars: json['sidecars'] == null ? null : (json['sidecars'] as List<dynamic>).cast<String>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'done': done,
        'failed': failed,
        'trashedTo': trashedTo,
        if (sidecars != null) 'sidecars': sidecars!,
      };
}

class VideoSmartAlbum {
  final String key;
  final int count;

  const VideoSmartAlbum({
    required this.key,
    required this.count,
  });

  factory VideoSmartAlbum.fromJson(Map<String, dynamic> json) => VideoSmartAlbum(
        key: json['key'] as String,
        count: json['count'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'count': count,
      };
}

class VideoSmartAlbumListResponse {
  final List<VideoSmartAlbum> items;

  const VideoSmartAlbumListResponse({
    required this.items,
  });

  factory VideoSmartAlbumListResponse.fromJson(Map<String, dynamic> json) => VideoSmartAlbumListResponse(
        items: (json['items'] as List<dynamic>).map((e) => VideoSmartAlbum.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class VideoListResponse {
  final List<VideoItem> items;
  final String? nextCursor;

  const VideoListResponse({
    required this.items,
    required this.nextCursor,
  });

  factory VideoListResponse.fromJson(Map<String, dynamic> json) => VideoListResponse(
        items: (json['items'] as List<dynamic>).map((e) => VideoItem.fromJson(e as Map<String, dynamic>)).toList(),
        nextCursor: json['nextCursor'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
        'nextCursor': nextCursor,
      };
}

class VideoImageFolderNode {
  final String name;
  final String path;
  final int count;
  final int imageCount;
  final int videoCount;
  final dynamic cover;

  const VideoImageFolderNode({
    required this.name,
    required this.path,
    required this.count,
    required this.imageCount,
    required this.videoCount,
    required this.cover,
  });

  factory VideoImageFolderNode.fromJson(Map<String, dynamic> json) => VideoImageFolderNode(
        name: json['name'] as String,
        path: json['path'] as String,
        count: json['count'] as int,
        imageCount: json['imageCount'] as int,
        videoCount: json['videoCount'] as int,
        cover: (json['cover'] as dynamic),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'path': path,
        'count': count,
        'imageCount': imageCount,
        'videoCount': videoCount,
        'cover': cover,
      };
}

class VideoImageFolderSegment {
  final String name;
  final String path;

  const VideoImageFolderSegment({
    required this.name,
    required this.path,
  });

  factory VideoImageFolderSegment.fromJson(Map<String, dynamic> json) => VideoImageFolderSegment(
        name: json['name'] as String,
        path: json['path'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'path': path,
      };
}

class VideoImageFolderResponse {
  final String path;
  final String? parentPath;
  final List<VideoImageFolderSegment> segments;
  final List<VideoImageFolderNode> folders;
  final int selfCount;
  final int selfImageCount;
  final int selfVideoCount;
  final bool hasSubFolders;

  const VideoImageFolderResponse({
    required this.path,
    required this.parentPath,
    required this.segments,
    required this.folders,
    required this.selfCount,
    required this.selfImageCount,
    required this.selfVideoCount,
    required this.hasSubFolders,
  });

  factory VideoImageFolderResponse.fromJson(Map<String, dynamic> json) => VideoImageFolderResponse(
        path: json['path'] as String,
        parentPath: json['parentPath'] as String?,
        segments: (json['segments'] as List<dynamic>).map((e) => VideoImageFolderSegment.fromJson(e as Map<String, dynamic>)).toList(),
        folders: (json['folders'] as List<dynamic>).map((e) => VideoImageFolderNode.fromJson(e as Map<String, dynamic>)).toList(),
        selfCount: json['selfCount'] as int,
        selfImageCount: json['selfImageCount'] as int,
        selfVideoCount: json['selfVideoCount'] as int,
        hasSubFolders: json['hasSubFolders'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'parentPath': parentPath,
        'segments': segments.map((e) => e.toJson()).toList(),
        'folders': folders.map((e) => e.toJson()).toList(),
        'selfCount': selfCount,
        'selfImageCount': selfImageCount,
        'selfVideoCount': selfVideoCount,
        'hasSubFolders': hasSubFolders,
      };
}

class VideoImageFolderDeleteBody {
  final String libraryId;
  final String path;

  const VideoImageFolderDeleteBody({
    required this.libraryId,
    required this.path,
  });

  factory VideoImageFolderDeleteBody.fromJson(Map<String, dynamic> json) => VideoImageFolderDeleteBody(
        libraryId: json['libraryId'] as String,
        path: json['path'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'libraryId': libraryId,
        'path': path,
      };
}

class VideoImageFolderDeleteResponse {
  final int removed;
  final String trashedTo;

  const VideoImageFolderDeleteResponse({
    required this.removed,
    required this.trashedTo,
  });

  factory VideoImageFolderDeleteResponse.fromJson(Map<String, dynamic> json) => VideoImageFolderDeleteResponse(
        removed: json['removed'] as int,
        trashedTo: json['trashedTo'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'removed': removed,
        'trashedTo': trashedTo,
      };
}

class VideoStreamUrlResponse {
  final String url;
  final int expiresInSec;
  final Map<String, dynamic>? compat;

  const VideoStreamUrlResponse({
    required this.url,
    required this.expiresInSec,
    this.compat,
  });

  factory VideoStreamUrlResponse.fromJson(Map<String, dynamic> json) => VideoStreamUrlResponse(
        url: json['url'] as String,
        expiresInSec: json['expiresInSec'] as int,
        compat: json['compat'] == null ? null : json['compat'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'expiresInSec': expiresInSec,
        if (compat != null) 'compat': compat!,
      };
}

class VideoStatsResponse {
  final int libraries;
  final int items;
  final int durationMs;

  const VideoStatsResponse({
    required this.libraries,
    required this.items,
    required this.durationMs,
  });

  factory VideoStatsResponse.fromJson(Map<String, dynamic> json) => VideoStatsResponse(
        libraries: json['libraries'] as int,
        items: json['items'] as int,
        durationMs: json['durationMs'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'libraries': libraries,
        'items': items,
        'durationMs': durationMs,
      };
}

class VideoAudioTrack {
  final int index;
  final String? codec;
  final String? language;
  final String? title;
  final int? channels;
  final String? channelLayout;
  final bool isDefault;

  const VideoAudioTrack({
    required this.index,
    required this.codec,
    required this.language,
    required this.title,
    required this.channels,
    required this.channelLayout,
    required this.isDefault,
  });

  factory VideoAudioTrack.fromJson(Map<String, dynamic> json) => VideoAudioTrack(
        index: json['index'] as int,
        codec: json['codec'] as String?,
        language: json['language'] as String?,
        title: json['title'] as String?,
        channels: json['channels'] as int?,
        channelLayout: json['channelLayout'] as String?,
        isDefault: json['isDefault'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'index': index,
        'codec': codec,
        'language': language,
        'title': title,
        'channels': channels,
        'channelLayout': channelLayout,
        'isDefault': isDefault,
      };
}

class VideoAudioTracksResponse {
  final List<VideoAudioTrack> items;

  const VideoAudioTracksResponse({
    required this.items,
  });

  factory VideoAudioTracksResponse.fromJson(Map<String, dynamic> json) => VideoAudioTracksResponse(
        items: (json['items'] as List<dynamic>).map((e) => VideoAudioTrack.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class VideoSeriesItem {
  final String name;
  final int seasons;
  final int episodes;
  final String? coverId;

  const VideoSeriesItem({
    required this.name,
    required this.seasons,
    required this.episodes,
    required this.coverId,
  });

  factory VideoSeriesItem.fromJson(Map<String, dynamic> json) => VideoSeriesItem(
        name: json['name'] as String,
        seasons: json['seasons'] as int,
        episodes: json['episodes'] as int,
        coverId: json['coverId'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'seasons': seasons,
        'episodes': episodes,
        'coverId': coverId,
      };
}

class VideoSeriesListResponse {
  final List<VideoSeriesItem> items;
  final String? nextCursor;

  const VideoSeriesListResponse({
    required this.items,
    required this.nextCursor,
  });

  factory VideoSeriesListResponse.fromJson(Map<String, dynamic> json) => VideoSeriesListResponse(
        items: (json['items'] as List<dynamic>).map((e) => VideoSeriesItem.fromJson(e as Map<String, dynamic>)).toList(),
        nextCursor: json['nextCursor'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
        'nextCursor': nextCursor,
      };
}

class VideoSeriesItemsResponse {
  final String name;
  final List<VideoItem> items;
  final List<VideoSeasonGap> missing;

  const VideoSeriesItemsResponse({
    required this.name,
    required this.items,
    required this.missing,
  });

  factory VideoSeriesItemsResponse.fromJson(Map<String, dynamic> json) => VideoSeriesItemsResponse(
        name: json['name'] as String,
        items: (json['items'] as List<dynamic>).map((e) => VideoItem.fromJson(e as Map<String, dynamic>)).toList(),
        missing: (json['missing'] as List<dynamic>).map((e) => VideoSeasonGap.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'items': items.map((e) => e.toJson()).toList(),
        'missing': missing.map((e) => e.toJson()).toList(),
      };
}

class VideoSeasonGap {
  final int season;
  final List<int> episodes;

  const VideoSeasonGap({
    required this.season,
    required this.episodes,
  });

  factory VideoSeasonGap.fromJson(Map<String, dynamic> json) => VideoSeasonGap(
        season: json['season'] as int,
        episodes: (json['episodes'] as List<dynamic>).cast<int>(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'season': season,
        'episodes': episodes,
      };
}

class VideoSeriesFavoriteBody {
  final String series;
  final String? libraryId;
  final bool favorite;

  const VideoSeriesFavoriteBody({
    required this.series,
    this.libraryId,
    required this.favorite,
  });

  factory VideoSeriesFavoriteBody.fromJson(Map<String, dynamic> json) => VideoSeriesFavoriteBody(
        series: json['series'] as String,
        libraryId: json['libraryId'] == null ? null : json['libraryId'] as String,
        favorite: json['favorite'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'series': series,
        if (libraryId != null) 'libraryId': libraryId!,
        'favorite': favorite,
      };
}

class VideoSeriesFavoriteResponse {
  final bool favorite;

  const VideoSeriesFavoriteResponse({
    required this.favorite,
  });

  factory VideoSeriesFavoriteResponse.fromJson(Map<String, dynamic> json) => VideoSeriesFavoriteResponse(
        favorite: json['favorite'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'favorite': favorite,
      };
}

class VideoSeriesFavoriteItem {
  final String series;
  final String libraryId;
  final int seasons;
  final int episodes;
  final String? coverId;
  final int createdAt;

  const VideoSeriesFavoriteItem({
    required this.series,
    required this.libraryId,
    required this.seasons,
    required this.episodes,
    this.coverId,
    required this.createdAt,
  });

  factory VideoSeriesFavoriteItem.fromJson(Map<String, dynamic> json) => VideoSeriesFavoriteItem(
        series: json['series'] as String,
        libraryId: json['libraryId'] as String,
        seasons: json['seasons'] as int,
        episodes: json['episodes'] as int,
        coverId: json['coverId'] == null ? null : json['coverId'] as String,
        createdAt: json['createdAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'series': series,
        'libraryId': libraryId,
        'seasons': seasons,
        'episodes': episodes,
        if (coverId != null) 'coverId': coverId!,
        'createdAt': createdAt,
      };
}

class VideoSeriesFavoriteListResponse {
  final List<VideoSeriesFavoriteItem> items;

  const VideoSeriesFavoriteListResponse({
    required this.items,
  });

  factory VideoSeriesFavoriteListResponse.fromJson(Map<String, dynamic> json) => VideoSeriesFavoriteListResponse(
        items: (json['items'] as List<dynamic>).map((e) => VideoSeriesFavoriteItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class VideoProgressBody {
  final String id;
  final String? position;
  final int percent;

  const VideoProgressBody({
    required this.id,
    this.position,
    required this.percent,
  });

  factory VideoProgressBody.fromJson(Map<String, dynamic> json) => VideoProgressBody(
        id: json['id'] as String,
        position: json['position'] == null ? null : json['position'] as String,
        percent: json['percent'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (position != null) 'position': position!,
        'percent': percent,
      };
}

class VideoProgress {
  final String itemId;
  final String position;
  final int percent;
  final int updatedAt;

  const VideoProgress({
    required this.itemId,
    required this.position,
    required this.percent,
    required this.updatedAt,
  });

  factory VideoProgress.fromJson(Map<String, dynamic> json) => VideoProgress(
        itemId: json['itemId'] as String,
        position: json['position'] as String,
        percent: json['percent'] as int,
        updatedAt: json['updatedAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'itemId': itemId,
        'position': position,
        'percent': percent,
        'updatedAt': updatedAt,
      };
}

class VideoProgressClearBody {
  final bool? onlyFinished;
  final String? series;

  const VideoProgressClearBody({
    this.onlyFinished,
    this.series,
  });

  factory VideoProgressClearBody.fromJson(Map<String, dynamic> json) => VideoProgressClearBody(
        onlyFinished: json['onlyFinished'] == null ? null : json['onlyFinished'] as bool,
        series: json['series'] == null ? null : json['series'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (onlyFinished != null) 'onlyFinished': onlyFinished!,
        if (series != null) 'series': series!,
      };
}

class VideoProgressClearResponse {
  final int cleared;

  const VideoProgressClearResponse({
    required this.cleared,
  });

  factory VideoProgressClearResponse.fromJson(Map<String, dynamic> json) => VideoProgressClearResponse(
        cleared: json['cleared'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'cleared': cleared,
      };
}

class VideoProgressItem {
  final String itemId;
  final String title;
  final String? series;
  final int? season;
  final int? episode;
  final String position;
  final int percent;
  final int updatedAt;

  const VideoProgressItem({
    required this.itemId,
    required this.title,
    required this.series,
    required this.season,
    required this.episode,
    required this.position,
    required this.percent,
    required this.updatedAt,
  });

  factory VideoProgressItem.fromJson(Map<String, dynamic> json) => VideoProgressItem(
        itemId: json['itemId'] as String,
        title: json['title'] as String,
        series: json['series'] as String?,
        season: json['season'] as int?,
        episode: json['episode'] as int?,
        position: json['position'] as String,
        percent: json['percent'] as int,
        updatedAt: json['updatedAt'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'itemId': itemId,
        'title': title,
        'series': series,
        'season': season,
        'episode': episode,
        'position': position,
        'percent': percent,
        'updatedAt': updatedAt,
      };
}

class VideoProgressListResponse {
  final List<VideoProgressItem> items;

  const VideoProgressListResponse({
    required this.items,
  });

  factory VideoProgressListResponse.fromJson(Map<String, dynamic> json) => VideoProgressListResponse(
        items: (json['items'] as List<dynamic>).map((e) => VideoProgressItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class VideoOkResponse {
  final bool ok;

  const VideoOkResponse({
    required this.ok,
  });

  factory VideoOkResponse.fromJson(Map<String, dynamic> json) => VideoOkResponse(
        ok: json['ok'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
      };
}

class VideoSubtitleFile {
  final String name;
  final String? lang;
  final String format;
  final int size;

  const VideoSubtitleFile({
    required this.name,
    required this.lang,
    required this.format,
    required this.size,
  });

  factory VideoSubtitleFile.fromJson(Map<String, dynamic> json) => VideoSubtitleFile(
        name: json['name'] as String,
        lang: json['lang'] as String?,
        format: json['format'] as String,
        size: json['size'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'lang': lang,
        'format': format,
        'size': size,
      };
}

class VideoSubtitleListResponse {
  final List<VideoSubtitleFile> items;

  const VideoSubtitleListResponse({
    required this.items,
  });

  factory VideoSubtitleListResponse.fromJson(Map<String, dynamic> json) => VideoSubtitleListResponse(
        items: (json['items'] as List<dynamic>).map((e) => VideoSubtitleFile.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class VideoSubtitleCue {
  final int startMs;
  final int endMs;
  final String text;

  const VideoSubtitleCue({
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  factory VideoSubtitleCue.fromJson(Map<String, dynamic> json) => VideoSubtitleCue(
        startMs: json['startMs'] as int,
        endMs: json['endMs'] as int,
        text: json['text'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'startMs': startMs,
        'endMs': endMs,
        'text': text,
      };
}

class VideoSubtitleResponse {
  final String name;
  final String? lang;
  final String format;
  final List<VideoSubtitleCue> cues;
  final String vtt;

  const VideoSubtitleResponse({
    required this.name,
    required this.lang,
    required this.format,
    required this.cues,
    required this.vtt,
  });

  factory VideoSubtitleResponse.fromJson(Map<String, dynamic> json) => VideoSubtitleResponse(
        name: json['name'] as String,
        lang: json['lang'] as String?,
        format: json['format'] as String,
        cues: (json['cues'] as List<dynamic>).map((e) => VideoSubtitleCue.fromJson(e as Map<String, dynamic>)).toList(),
        vtt: json['vtt'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'lang': lang,
        'format': format,
        'cues': cues.map((e) => e.toJson()).toList(),
        'vtt': vtt,
      };
}

class VideoErrorResponse {
  final String error;
  final String? message;
  final String? code;
  final String? traceId;
  final Map<String, dynamic>? details;

  const VideoErrorResponse({
    required this.error,
    this.message,
    this.code,
    this.traceId,
    this.details,
  });

  factory VideoErrorResponse.fromJson(Map<String, dynamic> json) => VideoErrorResponse(
        error: json['error'] as String,
        message: json['message'] == null ? null : json['message'] as String,
        code: json['code'] == null ? null : json['code'] as String,
        traceId: json['traceId'] == null ? null : json['traceId'] as String,
        details: json['details'] == null ? null : json['details'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'error': error,
        if (message != null) 'message': message!,
        if (code != null) 'code': code!,
        if (traceId != null) 'traceId': traceId!,
        if (details != null) 'details': details!,
      };
}

class VideoListCountResponse {
  final int total;
  final int scraped;

  const VideoListCountResponse({
    required this.total,
    required this.scraped,
  });

  factory VideoListCountResponse.fromJson(Map<String, dynamic> json) => VideoListCountResponse(
        total: json['total'] as int,
        scraped: json['scraped'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'total': total,
        'scraped': scraped,
      };
}

class VideoScrapeBody {
  final String id;
  final dynamic mode;
  final dynamic mediaType;
  final int? tmdbId;
  final bool? writeSidecar;

  const VideoScrapeBody({
    required this.id,
    this.mode,
    this.mediaType,
    this.tmdbId,
    this.writeSidecar,
  });

  factory VideoScrapeBody.fromJson(Map<String, dynamic> json) => VideoScrapeBody(
        id: json['id'] as String,
        mode: json['mode'] == null ? null : (json['mode'] as dynamic),
        mediaType: json['mediaType'] == null ? null : (json['mediaType'] as dynamic),
        tmdbId: json['tmdbId'] == null ? null : json['tmdbId'] as int,
        writeSidecar: json['writeSidecar'] == null ? null : json['writeSidecar'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (mode != null) 'mode': mode!,
        if (mediaType != null) 'mediaType': mediaType!,
        if (tmdbId != null) 'tmdbId': tmdbId!,
        if (writeSidecar != null) 'writeSidecar': writeSidecar!,
      };
}

class VideoScrapeResponse {
  final dynamic status;
  final String itemId;
  final String? source;
  final String? title;
  final int? fields;
  final bool? nfoWritten;
  final dynamic sidecar;
  final String? reason;

  const VideoScrapeResponse({
    required this.status,
    required this.itemId,
    this.source,
    this.title,
    this.fields,
    this.nfoWritten,
    this.sidecar,
    this.reason,
  });

  factory VideoScrapeResponse.fromJson(Map<String, dynamic> json) => VideoScrapeResponse(
        status: (json['status'] as dynamic),
        itemId: json['itemId'] as String,
        source: json['source'] == null ? null : json['source'] as String,
        title: json['title'] == null ? null : json['title'] as String,
        fields: json['fields'] == null ? null : json['fields'] as int,
        nfoWritten: json['nfoWritten'] == null ? null : json['nfoWritten'] as bool,
        sidecar: json['sidecar'] == null ? null : (json['sidecar'] as dynamic),
        reason: json['reason'] == null ? null : json['reason'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'status': status,
        'itemId': itemId,
        if (source != null) 'source': source!,
        if (title != null) 'title': title!,
        if (fields != null) 'fields': fields!,
        if (nfoWritten != null) 'nfoWritten': nfoWritten!,
        if (sidecar != null) 'sidecar': sidecar!,
        if (reason != null) 'reason': reason!,
      };
}

class VideoScrapeBatchBody {
  final String? libraryId;
  final List<String>? ids;
  final dynamic scope;
  final dynamic mode;
  final int? limit;

  const VideoScrapeBatchBody({
    this.libraryId,
    this.ids,
    this.scope,
    this.mode,
    this.limit,
  });

  factory VideoScrapeBatchBody.fromJson(Map<String, dynamic> json) => VideoScrapeBatchBody(
        libraryId: json['libraryId'] == null ? null : json['libraryId'] as String,
        ids: json['ids'] == null ? null : (json['ids'] as List<dynamic>).cast<String>(),
        scope: json['scope'] == null ? null : (json['scope'] as dynamic),
        mode: json['mode'] == null ? null : (json['mode'] as dynamic),
        limit: json['limit'] == null ? null : json['limit'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (libraryId != null) 'libraryId': libraryId!,
        if (ids != null) 'ids': ids!,
        if (scope != null) 'scope': scope!,
        if (mode != null) 'mode': mode!,
        if (limit != null) 'limit': limit!,
      };
}

class VideoScrapeBatchResponse {
  final int queued;
  final String? taskId;
  final int scanned;
  final int scraped;
  final int skipped;
  final int notfound;
  final int unavailable;

  const VideoScrapeBatchResponse({
    required this.queued,
    this.taskId,
    required this.scanned,
    required this.scraped,
    required this.skipped,
    required this.notfound,
    required this.unavailable,
  });

  factory VideoScrapeBatchResponse.fromJson(Map<String, dynamic> json) => VideoScrapeBatchResponse(
        queued: json['queued'] as int,
        taskId: json['taskId'] == null ? null : json['taskId'] as String,
        scanned: json['scanned'] as int,
        scraped: json['scraped'] as int,
        skipped: json['skipped'] as int,
        notfound: json['notfound'] as int,
        unavailable: json['unavailable'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'queued': queued,
        if (taskId != null) 'taskId': taskId!,
        'scanned': scanned,
        'scraped': scraped,
        'skipped': skipped,
        'notfound': notfound,
        'unavailable': unavailable,
      };
}

class VideoScrapeCleanupBody {
  final String id;

  const VideoScrapeCleanupBody({
    required this.id,
  });

  factory VideoScrapeCleanupBody.fromJson(Map<String, dynamic> json) => VideoScrapeCleanupBody(
        id: json['id'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
      };
}

class VideoScrapeCleanupResponse {
  final bool cleared;

  const VideoScrapeCleanupResponse({
    required this.cleared,
  });

  factory VideoScrapeCleanupResponse.fromJson(Map<String, dynamic> json) => VideoScrapeCleanupResponse(
        cleared: json['cleared'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'cleared': cleared,
      };
}

class VideoMatchNfoBody {
  final String id;
  final bool match;

  const VideoMatchNfoBody({
    required this.id,
    required this.match,
  });

  factory VideoMatchNfoBody.fromJson(Map<String, dynamic> json) => VideoMatchNfoBody(
        id: json['id'] as String,
        match: json['match'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'match': match,
      };
}

class VideoTmdbSearchBody {
  final String q;
  final dynamic mediaType;
  final int? year;

  const VideoTmdbSearchBody({
    required this.q,
    this.mediaType,
    this.year,
  });

  factory VideoTmdbSearchBody.fromJson(Map<String, dynamic> json) => VideoTmdbSearchBody(
        q: json['q'] as String,
        mediaType: json['mediaType'] == null ? null : (json['mediaType'] as dynamic),
        year: json['year'] == null ? null : json['year'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'q': q,
        if (mediaType != null) 'mediaType': mediaType!,
        if (year != null) 'year': year!,
      };
}

class VideoTmdbCandidate {
  final int tmdbId;
  final String mediaType;
  final String title;
  final String originalTitle;
  final int? year;
  final double? score;
  final String overview;
  final String? posterPath;

  const VideoTmdbCandidate({
    required this.tmdbId,
    required this.mediaType,
    required this.title,
    required this.originalTitle,
    required this.year,
    required this.score,
    required this.overview,
    required this.posterPath,
  });

  factory VideoTmdbCandidate.fromJson(Map<String, dynamic> json) => VideoTmdbCandidate(
        tmdbId: json['tmdbId'] as int,
        mediaType: json['mediaType'] as String,
        title: json['title'] as String,
        originalTitle: json['originalTitle'] as String,
        year: json['year'] as int?,
        score: (json['score'] as num?)?.toDouble(),
        overview: json['overview'] as String,
        posterPath: json['posterPath'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'tmdbId': tmdbId,
        'mediaType': mediaType,
        'title': title,
        'originalTitle': originalTitle,
        'year': year,
        'score': score,
        'overview': overview,
        'posterPath': posterPath,
      };
}

class VideoTmdbSearchResponse {
  final List<VideoTmdbCandidate> items;
  final bool configured;

  const VideoTmdbSearchResponse({
    required this.items,
    required this.configured,
  });

  factory VideoTmdbSearchResponse.fromJson(Map<String, dynamic> json) => VideoTmdbSearchResponse(
        items: (json['items'] as List<dynamic>).map((e) => VideoTmdbCandidate.fromJson(e as Map<String, dynamic>)).toList(),
        configured: json['configured'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(),
        'configured': configured,
      };
}

class VideoTmdbSettings {
  final String apiKey;
  final String language;
  final bool writeSidecar;
  final double minScore;
  final bool configured;

  const VideoTmdbSettings({
    required this.apiKey,
    required this.language,
    required this.writeSidecar,
    required this.minScore,
    required this.configured,
  });

  factory VideoTmdbSettings.fromJson(Map<String, dynamic> json) => VideoTmdbSettings(
        apiKey: json['apiKey'] as String,
        language: json['language'] as String,
        writeSidecar: json['writeSidecar'] as bool,
        minScore: (json['minScore'] as num).toDouble(),
        configured: json['configured'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'apiKey': apiKey,
        'language': language,
        'writeSidecar': writeSidecar,
        'minScore': minScore,
        'configured': configured,
      };
}

class VideoTmdbSettingsBody {
  final String? apiKey;
  final String? language;
  final bool? writeSidecar;
  final double? minScore;

  const VideoTmdbSettingsBody({
    this.apiKey,
    this.language,
    this.writeSidecar,
    this.minScore,
  });

  factory VideoTmdbSettingsBody.fromJson(Map<String, dynamic> json) => VideoTmdbSettingsBody(
        apiKey: json['apiKey'] == null ? null : json['apiKey'] as String,
        language: json['language'] == null ? null : json['language'] as String,
        writeSidecar: json['writeSidecar'] == null ? null : json['writeSidecar'] as bool,
        minScore: json['minScore'] == null ? null : (json['minScore'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (apiKey != null) 'apiKey': apiKey!,
        if (language != null) 'language': language!,
        if (writeSidecar != null) 'writeSidecar': writeSidecar!,
        if (minScore != null) 'minScore': minScore!,
      };
}

class VideoWatchBody {
  final List<String> ids;
  final bool watched;
  final bool? expandSeries;

  const VideoWatchBody({
    required this.ids,
    required this.watched,
    this.expandSeries,
  });

  factory VideoWatchBody.fromJson(Map<String, dynamic> json) => VideoWatchBody(
        ids: (json['ids'] as List<dynamic>).cast<String>(),
        watched: json['watched'] as bool,
        expandSeries: json['expandSeries'] == null ? null : json['expandSeries'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ids': ids,
        'watched': watched,
        if (expandSeries != null) 'expandSeries': expandSeries!,
      };
}

class VideoWatchResponse {
  final int updated;
  final int items;

  const VideoWatchResponse({
    required this.updated,
    required this.items,
  });

  factory VideoWatchResponse.fromJson(Map<String, dynamic> json) => VideoWatchResponse(
        updated: json['updated'] as int,
        items: json['items'] as int,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'updated': updated,
        'items': items,
      };
}

class VideoHomeSource {
  final String id;
  final String name;
  final String libType;
  final int items;
  final int onlineState;
  final String? coverId;
  final String? coverPath;
  final String? coverKind;

  const VideoHomeSource({
    required this.id,
    required this.name,
    required this.libType,
    required this.items,
    required this.onlineState,
    required this.coverId,
    this.coverPath,
    this.coverKind,
  });

  factory VideoHomeSource.fromJson(Map<String, dynamic> json) => VideoHomeSource(
        id: json['id'] as String,
        name: json['name'] as String,
        libType: json['libType'] as String,
        items: json['items'] as int,
        onlineState: json['onlineState'] as int,
        coverId: json['coverId'] as String?,
        coverPath: json['coverPath'] == null ? null : json['coverPath'] as String?,
        coverKind: json['coverKind'] == null ? null : json['coverKind'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'libType': libType,
        'items': items,
        'onlineState': onlineState,
        'coverId': coverId,
        if (coverPath != null) 'coverPath': coverPath!,
        if (coverKind != null) 'coverKind': coverKind!,
      };
}

class VideoHomeLibraryRow {
  final String libraryId;
  final String libraryName;
  final String? libType;
  final List<VideoItem> items;

  const VideoHomeLibraryRow({
    required this.libraryId,
    required this.libraryName,
    this.libType,
    required this.items,
  });

  factory VideoHomeLibraryRow.fromJson(Map<String, dynamic> json) => VideoHomeLibraryRow(
        libraryId: json['libraryId'] as String,
        libraryName: json['libraryName'] as String,
        libType: json['libType'] == null ? null : json['libType'] as String,
        items: (json['items'] as List<dynamic>).map((e) => VideoItem.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'libraryId': libraryId,
        'libraryName': libraryName,
        if (libType != null) 'libType': libType!,
        'items': items.map((e) => e.toJson()).toList(),
      };
}

class VideoHomeResponse {
  final List<VideoHomeSource> sources;
  final List<VideoItem> recommend;
  final List<VideoItem> recentPlay;
  final List<VideoHomeLibraryRow> recentAdd;
  final List<VideoProgress> progress;

  const VideoHomeResponse({
    required this.sources,
    required this.recommend,
    required this.recentPlay,
    required this.recentAdd,
    required this.progress,
  });

  factory VideoHomeResponse.fromJson(Map<String, dynamic> json) => VideoHomeResponse(
        sources: (json['sources'] as List<dynamic>).map((e) => VideoHomeSource.fromJson(e as Map<String, dynamic>)).toList(),
        recommend: (json['recommend'] as List<dynamic>).map((e) => VideoItem.fromJson(e as Map<String, dynamic>)).toList(),
        recentPlay: (json['recentPlay'] as List<dynamic>).map((e) => VideoItem.fromJson(e as Map<String, dynamic>)).toList(),
        recentAdd: (json['recentAdd'] as List<dynamic>).map((e) => VideoHomeLibraryRow.fromJson(e as Map<String, dynamic>)).toList(),
        progress: (json['progress'] as List<dynamic>).map((e) => VideoProgress.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sources': sources.map((e) => e.toJson()).toList(),
        'recommend': recommend.map((e) => e.toJson()).toList(),
        'recentPlay': recentPlay.map((e) => e.toJson()).toList(),
        'recentAdd': recentAdd.map((e) => e.toJson()).toList(),
        'progress': progress.map((e) => e.toJson()).toList(),
      };
}

class PlayerSessionCreateBody {
  final String id;
  final dynamic preset;
  final dynamic codec;
  final String? subtitle;
  final bool? audioNormalize;
  final bool? audioDownmix;
  final int? audioIndex;
  final bool? forceSdr;

  const PlayerSessionCreateBody({
    required this.id,
    this.preset,
    this.codec,
    this.subtitle,
    this.audioNormalize,
    this.audioDownmix,
    this.audioIndex,
    this.forceSdr,
  });

  factory PlayerSessionCreateBody.fromJson(Map<String, dynamic> json) => PlayerSessionCreateBody(
        id: json['id'] as String,
        preset: json['preset'] == null ? null : (json['preset'] as dynamic),
        codec: json['codec'] == null ? null : (json['codec'] as dynamic),
        subtitle: json['subtitle'] == null ? null : json['subtitle'] as String,
        audioNormalize: json['audioNormalize'] == null ? null : json['audioNormalize'] as bool,
        audioDownmix: json['audioDownmix'] == null ? null : json['audioDownmix'] as bool,
        audioIndex: json['audioIndex'] == null ? null : json['audioIndex'] as int,
        forceSdr: json['forceSdr'] == null ? null : json['forceSdr'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (preset != null) 'preset': preset!,
        if (codec != null) 'codec': codec!,
        if (subtitle != null) 'subtitle': subtitle!,
        if (audioNormalize != null) 'audioNormalize': audioNormalize!,
        if (audioDownmix != null) 'audioDownmix': audioDownmix!,
        if (audioIndex != null) 'audioIndex': audioIndex!,
        if (forceSdr != null) 'forceSdr': forceSdr!,
      };
}

class PlayerSessionCreated {
  final String id;
  final String url;

  const PlayerSessionCreated({
    required this.id,
    required this.url,
  });

  factory PlayerSessionCreated.fromJson(Map<String, dynamic> json) => PlayerSessionCreated(
        id: json['id'] as String,
        url: json['url'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'url': url,
      };
}

class PlayerSessionItem {
  final String id;
  final String itemId;
  final String preset;
  final String? codec;
  final String? container;
  final String? subtitle;
  final dynamic status;
  final int segments;
  final String? error;
  final String url;
  final int createdAt;
  final int updatedAt;
  final int? audioIndex;
  final bool? hdrToSdr;

  const PlayerSessionItem({
    required this.id,
    required this.itemId,
    required this.preset,
    this.codec,
    this.container,
    required this.subtitle,
    required this.status,
    required this.segments,
    required this.error,
    required this.url,
    required this.createdAt,
    required this.updatedAt,
    this.audioIndex,
    this.hdrToSdr,
  });

  factory PlayerSessionItem.fromJson(Map<String, dynamic> json) => PlayerSessionItem(
        id: json['id'] as String,
        itemId: json['itemId'] as String,
        preset: json['preset'] as String,
        codec: json['codec'] == null ? null : json['codec'] as String,
        container: json['container'] == null ? null : json['container'] as String,
        subtitle: json['subtitle'] as String?,
        status: (json['status'] as dynamic),
        segments: json['segments'] as int,
        error: json['error'] as String?,
        url: json['url'] as String,
        createdAt: json['createdAt'] as int,
        updatedAt: json['updatedAt'] as int,
        audioIndex: json['audioIndex'] == null ? null : json['audioIndex'] as int,
        hdrToSdr: json['hdrToSdr'] == null ? null : json['hdrToSdr'] as bool,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'itemId': itemId,
        'preset': preset,
        if (codec != null) 'codec': codec!,
        if (container != null) 'container': container!,
        'subtitle': subtitle,
        'status': status,
        'segments': segments,
        'error': error,
        'url': url,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        if (audioIndex != null) 'audioIndex': audioIndex!,
        if (hdrToSdr != null) 'hdrToSdr': hdrToSdr!,
      };
}

class PlayerErrorResponse {
  final String error;
  final String? message;
  final String? code;
  final String? traceId;
  final Map<String, dynamic>? details;

  const PlayerErrorResponse({
    required this.error,
    this.message,
    this.code,
    this.traceId,
    this.details,
  });

  factory PlayerErrorResponse.fromJson(Map<String, dynamic> json) => PlayerErrorResponse(
        error: json['error'] as String,
        message: json['message'] == null ? null : json['message'] as String,
        code: json['code'] == null ? null : json['code'] as String,
        traceId: json['traceId'] == null ? null : json['traceId'] as String,
        details: json['details'] == null ? null : json['details'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'error': error,
        if (message != null) 'message': message!,
        if (code != null) 'code': code!,
        if (traceId != null) 'traceId': traceId!,
        if (details != null) 'details': details!,
      };
}
